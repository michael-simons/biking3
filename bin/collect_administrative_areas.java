///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 24
//DEPS info.picocli:picocli:4.7.6
//DEPS org.duckdb:duckdb_jdbc:1.2.1
//RUNTIME_OPTIONS --enable-native-access=ALL-UNNAMED

import java.io.FileInputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.function.Function;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.zip.GZIPInputStream;

import picocli.CommandLine;

/**
 * Base borders are sourced from
 * <a href="https://www.naturalearthdata.com/downloads/10m-cultural-vectors/">Natural
 * Earth Data</a>, global administrative layers from <a href="https://gadm.org">GADM</a>.
 *
 * @author Michael J. Simons
 */
@SuppressWarnings({ "SqlDialectInspection", "SqlNoDataSourceInspection" })
@CommandLine.Command(name = "collect-administrative-areas", mixinStandardHelpOptions = true,
		description = "Computes countries per track and than tries to collect administrative areas as deep as possible.",
		subcommands = { CommandLine.HelpCommand.class })
public class collect_administrative_areas implements Callable<Integer> {

	private static final String USER_AGENT = "biking3 (collect-administrative-areas)";

	private static final String GADM_VERSION = "4.1";

	private static final String GADM_PREFIX = "gadm" + GADM_VERSION.replace(".", "");

	@CommandLine.Option(names = "--tracks-dir", required = true, defaultValue = "Garmin/Tracks")
	private Path tracksDir;

	@CommandLine.Option(names = "--border-dir", required = true)
	private Path borderDir;

	/**
	 * Use a name from the <a href=
	 * "https://www.naturalearthdata.com/downloads/10m-cultural-vectors/">cultural-vectors</a>.
	 */
	@CommandLine.Option(names = "--countries-to-use", required = true,
			defaultValue = "ne_10m_admin_0_countries_deu.zip")
	private String countriesToUse;

	@CommandLine.Option(names = "--max-files", required = true, defaultValue = "100")
	private int maxFiles;

	@CommandLine.Parameters(arity = "1")
	private Path database;

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

		var databaseResolved = userDirectory.resolve(this.database);
		if (!Files.isRegularFile(databaseResolved)) {
			System.err.println("Database not found: " + this.database);
			return CommandLine.ExitCode.USAGE;
		}

		var borderDirResolved = userDirectory.resolve(this.borderDir);
		if (Files.isRegularFile(borderDirResolved)) {
			System.err.println(this.borderDir + " already exists and is a file");
			return CommandLine.ExitCode.USAGE;
		}
		if (!Files.exists(borderDirResolved)) {
			Files.createDirectories(borderDirResolved);
		}

		try (var areas = Areas.of(tracksDirResolved, borderDirResolved, this.countriesToUse, this.maxFiles,
				databaseResolved)) {
			areas.collect();
		}

		return CommandLine.ExitCode.OK;
	}

	/**
	 * Represents an administrative area.
	 *
	 * @param level the level of the area
	 * @param code the ISO 3166-1 alpha-3 code, if available
	 * @param name the local name of the area
	 */
	record Area(int level, String code, String name) {
	}

	static final class Areas implements AutoCloseable {

		private final Map<String, Path> allGpxFiles;

		private final Path gadmDir;

		private final int maxFiles;

		private final Connection connection;

		private final PreparedStatement selectNewActivitiesStmt;

		private final PreparedStatement selectCountriesStmt;

		private final PreparedStatement selectAreaStmt;

		private final PreparedStatement storeAreasStmt;

		private final PreparedStatement updateStmt;

		private final HttpClient httpClient = HttpClient.newHttpClient();

		static Areas of(Path tracksDir, Path borderDir, String countriesToUse, int maxFiles, Path database)
				throws Exception {
			try (var allFiles = Files.list(tracksDir)) {
				var allGpxFiles = allFiles.filter(p -> p.getFileName().toString().endsWith(".gpx.gz"))
					.collect(Collectors.toMap(p -> p.getFileName().toString(), Function.identity()));

				var connection = DriverManager.getConnection("jdbc:duckdb:" + database.toAbsolutePath());
				connection.setAutoCommit(false);

				try (var stmt = connection.createStatement()) {
					stmt.execute("INSTALL spatial");
					stmt.execute("LOAD spatial");
				}

				var countries = borderDir.resolve("countries");
				if (!Files.isDirectory(countries)) {
					var target = Files.createTempFile(collect_administrative_areas.class.getSimpleName() + "-", ".zip");
					var uri = "https://naciscdn.org/naturalearth/10m/cultural/%s".formatted(countriesToUse);
					System.err.printf("Downloading countries from %s%n", uri);
					try (var httpClient = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.ALWAYS).build()) {
						var response = httpClient.send(
								HttpRequest.newBuilder(URI.create(uri)).header("User-Agent", USER_AGENT).GET().build(),
								HttpResponse.BodyHandlers.ofFile(target));

						if (response.statusCode() != 200) {
							System.err.printf("Download failed: %d%n", response.statusCode());
							throw new RuntimeException("No base country data and download failed");
						}

						var process = new ProcessBuilder("unzip", target.toAbsolutePath().toString(), "-d",
								countries.toAbsolutePath().toString())
							.start();
						process.waitFor();
					}
					finally {
						Files.deleteIfExists(target);
					}
				}

				var gadmDir = borderDir.resolve("GADM");
				if (!Files.isDirectory(gadmDir)) {
					Files.createDirectories(gadmDir);
				}

				// Load the countries into a temporary table, no need to do this over and
				// over again
				var query = "CREATE TEMPORARY TABLE countries AS (SELECT adm0_a3 AS country_code, name_en AS name, geom FROM st_read(?))";
				try (var stmt = connection.prepareStatement(query)) {
					var shapefile = countries.resolve(countriesToUse.replace(".zip", ".shp"))
						.toAbsolutePath()
						.toString();
					stmt.setString(1, shapefile);
					stmt.execute();
				}
				connection.commit();

				return new Areas(allGpxFiles, gadmDir, maxFiles, connection);
			}
		}

		private Areas(Map<String, Path> allGpxFiles, Path gadmDir, int maxFiles, Connection connection)
				throws SQLException {

			this.allGpxFiles = allGpxFiles;
			this.gadmDir = gadmDir;
			this.maxFiles = maxFiles;
			this.connection = connection;

			this.selectNewActivitiesStmt = connection.prepareStatement("""
					SELECT garmin_id
					FROM garmin_activities
					WHERE gpx_available AND NOT administrative_areas_processed
					  AND activity_type <> 'virtual_ride'
					ORDER BY started_on ASC
					LIMIT ?
					""");

			this.selectCountriesStmt = connection.prepareStatement("""
					SELECT c.country_code, c.name
					FROM st_read(?, layer = 'tracks') t
					JOIN countries c ON st_intersects(c.geom, t.geom)
					""");

			this.selectAreaStmt = connection.prepareStatement("""
					SELECT b.*
					FROM st_read(?, layer = 'tracks') t
					JOIN query_table(?) b ON st_intersects(b.geom, t.geom)
					""");

			this.storeAreasStmt = connection.prepareStatement("""
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
					""");

			this.updateStmt = connection.prepareStatement(
					"UPDATE garmin_activities SET administrative_areas_processed = true WHERE garmin_id = ?");
		}

		@Override
		public void close() throws Exception {
			this.selectNewActivitiesStmt.close();
			this.selectCountriesStmt.close();
			this.selectAreaStmt.close();
			this.storeAreasStmt.close();
			this.connection.close();
			this.httpClient.close();
		}

		void collect() throws Exception {

			var files = findUnprocessedActivities();
			var tmpFiles = new ArrayList<Path>();

			try {
				for (var file : files) {
					var tmp = Files.createTempFile(collect_administrative_areas.class.getSimpleName() + "-", ".gpx");
					try (var gis = new GZIPInputStream(new FileInputStream(file.path().toFile()))) {
						Files.copy(gis, tmp, StandardCopyOption.REPLACE_EXISTING);
					}
					tmpFiles.add(tmp);

					System.err.printf("Processing %d via %s%n", file.id(), tmp);
					storeAreas(file, selectAreasByCountry(selectCountries(tmp)));
				}
			}
			finally {
				for (Path tmpFile : tmpFiles) {
					Files.deleteIfExists(tmpFile);
				}
			}
		}

		private TrackWithCountries selectCountries(Path trackFile) throws Exception {

			this.selectCountriesStmt.setString(1, trackFile.toAbsolutePath().toString());

			var countries = new ArrayList<Area>();
			try (var rs = this.selectCountriesStmt.executeQuery()) {
				while (rs.next()) {
					var countryCode = rs.getString("country_code");
					if (bordersFor(countryCode).isEmpty()) {
						System.err.printf("No boundaries for %s, skipping.%n", countryCode);
						continue;
					}
					countries.add(new Area(0, countryCode, rs.getString("name")));
				}
			}
			return new TrackWithCountries(trackFile, countries);
		}

		private Optional<Path> bordersFor(String countryCode) throws Exception {

			var shapeDirectory = this.gadmDir.resolve("%s_%s_shp".formatted(GADM_PREFIX, countryCode));
			if (Files.isDirectory(shapeDirectory)) {
				return Optional.of(shapeDirectory);
			}

			var shapeZip = "%s.zip".formatted(shapeDirectory.getFileName().toString());
			var shapeUri = URI
				.create("https://geodata.ucdavis.edu/gadm/gadm%s/shp/%s".formatted(GADM_VERSION, shapeZip));
			var zipFile = this.gadmDir.resolve(shapeZip);
			System.err.printf("Downloading %s%n", shapeUri);
			var response = this.httpClient.send(
					HttpRequest.newBuilder(shapeUri).header("User-Agent", USER_AGENT).GET().build(),
					HttpResponse.BodyHandlers.ofFile(zipFile));

			try {
				if (response.statusCode() != 200) {
					System.err.printf("Download failed: %d%n", response.statusCode());
					return Optional.empty();
				}

				var process = new ProcessBuilder("unzip", zipFile.toAbsolutePath().toString(), "-d",
						shapeDirectory.toAbsolutePath().toString())
					.start();
				process.waitFor();
			}
			finally {
				Files.deleteIfExists(zipFile);
			}

			return Optional.of(shapeDirectory);
		}

		private Set<List<Area>> selectAreasByCountry(TrackWithCountries trackWithCountries) throws Exception {

			var result = new HashSet<List<Area>>();

			for (var lvl0 : trackWithCountries.countries()) {
				var shape = "%s_%s_shp".formatted(GADM_PREFIX, lvl0.code());
				var shapeDirectory = this.gadmDir.resolve(shape);

				var maxLevel = 0;
				var shapePattern = Pattern.compile("%s_%s_\\d+.shp".formatted(GADM_PREFIX, lvl0.code()))
					.asMatchPredicate();
				try (var allShapes = Files.list(shapeDirectory)
					.filter(p -> shapePattern.test(p.getFileName().toString()))) {
					maxLevel = (int) (allShapes.count() - 1);
				}
				var shapeFile = this.gadmDir
					.resolve(shapeDirectory, Path.of("%s_%s_%d.shp".formatted(GADM_PREFIX, lvl0.code(), maxLevel)))
					.toAbsolutePath();
				var tableName = "\"%s\"".formatted(shapeFile.getFileName().toString());

				// We will most likely use this again
				try (var stmt = this.connection.prepareStatement(
						"CREATE TEMPORARY TABLE IF NOT EXISTS %s AS SELECT * FROM st_read(?)".formatted(tableName))) {
					stmt.setString(1, shapeFile.toString());
					stmt.execute();
				}

				this.selectAreaStmt.setString(1, trackWithCountries.file().toString());
				this.selectAreaStmt.setString(2, tableName);

				try (var rs = this.selectAreaStmt.executeQuery()) {
					while (rs.next()) {
						var areas = new ArrayList<Area>();
						areas.add(lvl0);
						for (int l = 1; l < maxLevel + 1; ++l) {
							areas.add(new Area(l, lvl0.code(), rs.getString("NAME_%d".formatted(l))));
						}
						result.add(areas);
					}
				}
			}

			return result;
		}

		private void storeAreas(IdAndPath file, Set<List<Area>> areas) throws SQLException {

			for (var hierarchy : areas) {
				var parentId = -1L;
				var countryCode = hierarchy.getFirst().code();
				for (var area : hierarchy) {
					this.storeAreasStmt.setLong(1, parentId);
					this.storeAreasStmt.setString(2, countryCode);
					this.storeAreasStmt.setInt(3, area.level());
					this.storeAreasStmt.setString(4, area.name());
					this.storeAreasStmt.setLong(5, file.id());
					this.storeAreasStmt.execute();

					try (var rs = this.storeAreasStmt.getResultSet()) {
						rs.next();
						parentId = rs.getLong("id");
					}
				}
			}

			this.updateStmt.setLong(1, file.id());
			this.updateStmt.executeUpdate();
			this.connection.commit();
		}

		private Set<IdAndPath> findUnprocessedActivities() throws SQLException {

			this.selectNewActivitiesStmt.setInt(1, this.maxFiles);
			var unprocessedActivities = new HashSet<IdAndPath>();
			try (var result = this.selectNewActivitiesStmt.executeQuery()) {
				while (result.next()) {
					var id = result.getLong(1);
					var path = this.allGpxFiles.get(id + ".gpx.gz");
					if (path != null) {
						unprocessedActivities.add(new IdAndPath(id, path));
					}
				}
			}
			return unprocessedActivities;
		}

		record IdAndPath(Long id, Path path) {
		}

		record TrackWithCountries(Path file, List<Area> countries) {
		}

	}

}
