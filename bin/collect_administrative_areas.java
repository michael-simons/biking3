///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 24
//DEPS info.picocli:picocli:4.7.6
//DEPS org.duckdb:duckdb_jdbc:1.2.1
//DEPS com.fasterxml.jackson.core:jackson-databind:2.18.3
//RUNTIME_OPTIONS --enable-native-access=ALL-UNNAMED

import java.io.FileInputStream;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ThreadLocalRandom;
import java.util.function.Function;
import java.util.function.Predicate;
import java.util.stream.Collectors;
import java.util.stream.Gatherers;
import java.util.stream.Stream;
import java.util.zip.GZIPInputStream;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;
import picocli.CommandLine;

@SuppressWarnings( {"SqlDialectInspection", "SqlNoDataSourceInspection"})
@CommandLine.Command(
	name = "collect-administrative-areas",
	mixinStandardHelpOptions = true,
	description = "Tries to map-match Garmin activities with available GPX and does reverse address lookups on the ways to figure out all administrative areas covered.",
	subcommands = {CommandLine.HelpCommand.class}
)
public class collect_administrative_areas implements Callable<Integer> {

	private static final String USER_AGENT = "biking3 (collect-administrative-areas)";

	@CommandLine.Option(names = "--tracks-dir", required = true, defaultValue = "Garmin/Tracks")
	private Path tracksDir;

	@CommandLine.Option(names = "--email-address", required = true)
	private String emailAddress;

	@CommandLine.Option(names = "--max-files", required = true, defaultValue = "100")
	private int maxFiles;

	@CommandLine.Parameters(arity = "1")
	private Path database;

	/**
	 * A polyline that implements the algorithm defined in <a href="https://developers.google.com/maps/documentation/utilities/polylinealgorithm">Encoded Polyline Algorithm Format</a>.
	 * Google uses a scale of 5, so if you want to test using <a href="https://developers.google.com/maps/documentation/routes/polylinedecoder?hl=en">this</a> tool, set scale to 5.
	 * Valhalla of course uses 6 (see <a href="https://valhalla.github.io/valhalla/decoding/">decoding</a>).
	 */
	@JsonSerialize(using = ToStringSerializer.class)
	static class Polyline {

		record Point(int x, int y) {

			private Point offset(Point other) {
				return new Point(x - other.x(), y - other.y());
			}

			private String encode() {
				return encode0(x) + encode0(y);
			}

			private String encode0(int v) {
				var num = v << 1;
				if (v < 0) {
					num = ~num;
				}

				var result = new StringBuilder();
				while (num >= 0x20) {
					int nextValue = (0x20 | (num & 0x1f)) + 63;
					result.append((char) (nextValue));
					num >>= 5;
				}

				num += 63;
				result.append((char) (num));
				return result.toString();
			}
		}

		private final List<Point> points = new ArrayList<>();

		private final int scale;

		Polyline() {
			this(6);
		}

		Polyline(int scale) {
			this.scale = (int) Math.pow(10, scale);
		}

		void add(double x, double y) {
			this.points.add(new Point((int) Math.floor(x * scale), (int) Math.floor(y * scale)));
		}

		@Override
		public String toString() {
			if (points.isEmpty()) {
				return "";
			}
			var initial = points.getFirst().encode();
			if (points.size() == 1) {
				return initial;
			}
			var remainder = points.stream().gather(Gatherers.windowSliding(2)).map(pair -> pair.getLast().offset(pair.getFirst()).encode()).collect(Collectors.joining());
			return initial + remainder;
		}
	}

	/**
	 * Represents an administrative area.
	 * Country specific levels are <a href="https://wiki.openstreetmap.org/wiki/Tag:boundary%3Dadministrative#Country_specific_values_%E2%80%8B%E2%80%8Bof_the_key_admin_level=*">here</a>.
	 *
	 * @param level the level of the area
	 * @param code  the ISO3166-1 code, if available
	 * @param name  the local name of the area
	 */
	record Area(int level, String code, String name) {
	}

	private static final TypeReference<Map<String, Object>> MAP_OF_OBJECTS = new TypeReference<>() {
	};

	public static void main(String... args) {
		int exitCode = new CommandLine(new collect_administrative_areas()).execute(args);
		System.exit(exitCode);
	}

	@Override
	public Integer call() throws Exception {

		var userDirectory = Path.of(System.getProperty("user.dir"));
		var tracksDirResolved = userDirectory.resolve(this.tracksDir);
		if (!Files.isDirectory(tracksDirResolved)) {
			System.err.println("Directory containing tracks not found: " + tracksDirResolved);
			return CommandLine.ExitCode.USAGE;
		}

		database = userDirectory.resolve(database);
		if (!Files.isRegularFile(database)) {
			System.err.println("Database not found: " + database);
			return CommandLine.ExitCode.USAGE;
		}

		try (var areas = Areas.of(tracksDirResolved, emailAddress, maxFiles, database)) {
			areas.collect();
		}

		return CommandLine.ExitCode.OK;
	}

	@SuppressWarnings("unchecked")
	static class Areas implements AutoCloseable {

		record IdAndPath(Long id, Path path) {
		}

		private final Map<String, Path> allGpxFiles;

		private final String emailAddress;

		private final Connection connection;

		private final int maxFiles;

		private final HttpClient httpClient = HttpClient.newHttpClient();

		private final ObjectMapper om = new ObjectMapper();

		private final Set<Number> knownIds = new HashSet<>();

		static Areas of(Path tracksDir, String emailAddress, int maxFiles, Path database) throws SQLException, IOException {
			try (var allFiles = Files.list(tracksDir)) {
				var allGpxFiles = allFiles
					.filter(p -> p.getFileName().toString().endsWith(".gpx.gz"))
					.collect(Collectors.toMap(p -> p.getFileName().toString(), Function.identity()));

				var connection = DriverManager.getConnection("jdbc:duckdb:" + database.toAbsolutePath());
				connection.setAutoCommit(false);

				try (var stmt = connection.createStatement()) {
					stmt.execute("INSTALL spatial");
					stmt.execute("LOAD spatial");
				}
				return new Areas(allGpxFiles, emailAddress, maxFiles, connection);
			}
		}

		private Areas(Map<String, Path> allGpxFiles, String emailAddress, int maxFiles, Connection connection) {
			this.allGpxFiles = allGpxFiles;
			this.emailAddress = emailAddress;
			this.connection = connection;
			this.maxFiles = maxFiles;
		}

		@Override
		public void close() throws Exception {
			if (this.connection != null) {
				this.connection.close();
			}
			this.httpClient.close();
		}

		void collect() throws SQLException, IOException, InterruptedException {

			var files = findUnprocessedActivities();
			var tmpFiles = new ArrayList<Path>();

			try (var stmt = connection.prepareStatement("SELECT st_x(geom) AS long, st_y(geom) AS lat FROM st_read(?, layer = 'track_points')")) {
				for (var file : files) {
					var tmp = Files.createTempFile("collect-administrative-areas-", ".gpx");
					try (var gis = new GZIPInputStream(new FileInputStream(file.path().toFile()))) {
						Files.copy(gis, tmp, StandardCopyOption.REPLACE_EXISTING);
					}
					tmpFiles.add(tmp);

					System.err.printf("Processing %s%n", tmp.toString());
					stmt.setString(1, tmp.toString());
					var polyline = new Polyline();
					try (var points = stmt.executeQuery()) {
						while (points.next()) {
							polyline.add(points.getDouble("lat"), points.getDouble("long"));
						}
					}

					storeAreas(file, lookupAreas(mapMatch(polyline)));
				}
			} finally {
				for (Path tmpFile : tmpFiles) {
					Files.deleteIfExists(tmpFile);
				}
			}
		}

		private void storeAreas(IdAndPath file, Set<List<Area>> areas) throws SQLException {
			try (
				var stmtArea = connection.prepareStatement("""
					INSERT INTO administrative_areas BY NAME
					SELECT ? AS parent_id,
					       ? AS country_code,
					       ? AS level,
					       ? AS name,
					       1 AS visited_count,
					       started_on::date AS visited_first_on,
					       started_on::date AS visited_last_on
					FROM garmin_activities WHERE garmin_id = ?
					ON CONFLICT (parent_id, name) DO UPDATE SET
					    id = id,
						   visited_count = visited_count + 1,
						   visited_first_on = least(visited_first_on, excluded.visited_first_on),
						   visited_last_on = greatest(visited_last_on, excluded.visited_last_on),
					RETURNING id
					""")
			) {
				for (var hierarchy : areas) {
					var parentId = -1L;
					var countryCode = hierarchy.getFirst().code();
					for (var area : hierarchy) {
						stmtArea.setLong(1, parentId);
						stmtArea.setString(2, countryCode);
						stmtArea.setInt(3, area.level());
						stmtArea.setString(4, area.name());
						stmtArea.setLong(5, file.id());
						stmtArea.execute();

						try (var rs = stmtArea.getResultSet()) {
							rs.next();
							parentId = rs.getLong("id");
						}
					}
				}

				try (var updateStmt = connection.prepareStatement("UPDATE garmin_activities SET administrative_areas_processed = true WHERE garmin_id = ?")) {
					updateStmt.setLong(1, file.id());
					updateStmt.executeUpdate();
				}
				connection.commit();
			}
		}

		//
		// See https://valhalla.github.io/valhalla/api/map-matching/api-reference/
		//
		private List<Map<String, Object>> mapMatch(Polyline polyline) throws IOException, InterruptedException {
			var request = HttpRequest.newBuilder(URI.create("https://valhalla1.openstreetmap.de/trace_attributes"))
				.header("User-Agent", USER_AGENT)
				.POST(HttpRequest.BodyPublishers.ofString(om.writeValueAsString(Map.of(
					"encoded_polyline", polyline.toString(),
					"costing", "auto",
					"filters", Map.of("attributes", List.of("edge.way_id"), "action", "include")
				))))
				.build();

			var mapMatchResponse = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
			if (mapMatchResponse.statusCode() != 200) {
				return List.of();
			}

			return (List<Map<String, Object>>) om.readValue(mapMatchResponse.body(), MAP_OF_OBJECTS).get("edges");
		}

		//
		// See https://nominatim.org/release-docs/latest/api/Lookup/
		//
		private Set<List<Area>> lookupAreas(List<Map<String, Object>> edges) throws
			IOException, InterruptedException {

			var newIds = edges.stream().map(edge -> (Number) edge.get("way_id"))
				.filter(Predicate.not(knownIds::contains))
				.collect(Collectors.toSet());

			this.knownIds.addAll(newIds);

			var requests = newIds.stream().gather(Gatherers.windowFixed(50))
				.map(ids -> ids.stream().map(id -> "W" + id).collect(Collectors.joining(",")))
				.map(ids -> HttpRequest.newBuilder(URI.create("https://nominatim.openstreetmap.org/lookup?format=geocodejson&addressdetails=1&osm_ids=%s&email=%s".formatted(ids, emailAddress)))
					.header("User-Agent", USER_AGENT)
					.header("Accept-Language", "")
					.GET().build()).toList();

			var countries = new HashSet<List<Area>>();
			for (var httpRequest : requests) {
				var response = httpClient.send(httpRequest, HttpResponse.BodyHandlers.ofInputStream());
				if (response.statusCode() != 200) {
					continue;
				}
				var features = (List<Map<String, Object>>) om.readValue(response.body(), MAP_OF_OBJECTS).get("features");

				for (var feature : features) {
					var properties = (Map<String, Object>) ((Map<String, Object>) feature.get("properties")).get("geocoding");
					var country = new Area(2, (String) properties.get("country_code"), (String) properties.get("country"));
					var areas = Stream.concat(
							Stream.of(country),
							((Map<String, String>) properties.get("admin")).entrySet()
								.stream()
								.map(e -> new Area(Integer.parseInt(e.getKey().substring(5)), null, e.getValue()))
								.distinct())
						.sorted(Comparator.comparing(Area::level))
						.toList();
					countries.add(areas);
				}
				try {
					// nominatim ask for not more than 1 request per second, so between 1 and 5 seconds is probably good enough.
					Thread.sleep(ThreadLocalRandom.current().nextInt(5) * 1000);
				} catch (InterruptedException e) {
					Thread.currentThread().interrupt();
				}
			}
			return countries;
		}

		private Set<IdAndPath> findUnprocessedActivities() throws SQLException {
			try (
				var stmt = connection.prepareStatement("""
					SELECT garmin_id
					FROM garmin_activities
					WHERE gpx_available
					  AND NOT administrative_areas_processed
					ORDER BY started_on ASC
					LIMIT ?""")
			) {
				stmt.setInt(1, maxFiles);
				var unprocessedActivities = new HashSet<IdAndPath>();
				try (var result = stmt.executeQuery()) {
					while (result.next()) {
						var id = result.getLong(1);
						var path = allGpxFiles.get(id + ".gpx.gz");
						if (path != null) {
							unprocessedActivities.add(new IdAndPath(id, path));
						}
					}
				}
				return unprocessedActivities;
			}
		}
	}
}
