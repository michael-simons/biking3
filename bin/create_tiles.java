///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 24
//DEPS info.picocli:picocli:4.7.6
//DEPS org.duckdb:duckdb_jdbc:1.3.1.0

import java.io.FileInputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import java.util.stream.Collectors;
import java.util.zip.GZIPInputStream;

import picocli.CommandLine;
import picocli.CommandLine.ExitCode;

@SuppressWarnings( {"SqlDialectInspection", "SqlNoDataSourceInspection"})
@CommandLine.Command(
	name = "create-tiles",
	mixinStandardHelpOptions = true,
	description = "Processes new Garmin activities, (re)visits tiles and updates the clusters.",
	subcommands = {CommandLine.HelpCommand.class}
)
public class create_tiles implements Callable<Integer> {

	@CommandLine.Option(names = "--tracks-dir", required = true, defaultValue = "Garmin/Tracks")
	private Path tracksDir;

	@CommandLine.Option(names = "--zoom", required = true, defaultValue = "14")
	private int zoom;

	@CommandLine.Parameters(arity = "1")
	private Path database;

	public static void main(String... args) {
		int exitCode = new CommandLine(new create_tiles()).execute(args);
		System.exit(exitCode);
	}

	@Override
	public Integer call() throws Exception {

		var userDirectory = Path.of(System.getProperty("user.dir"));
		var tracksDirResolved = userDirectory.resolve(this.tracksDir);
		if (!Files.isDirectory(tracksDirResolved)) {
			System.err.println("Directory containing tracks not found: " + tracksDirResolved);
			return ExitCode.USAGE;
		}

		database = userDirectory.resolve(database);
		if (!Files.isRegularFile(database)) {
			System.err.println("Database not found: " + database);
			return ExitCode.USAGE;
		}

		try (var tiles = Tiles.of(tracksDirResolved, database, zoom)) {
			tiles.update();
		}

		return ExitCode.OK;
	}

	static class Tiles implements AutoCloseable {

		record IdAndPath(Long id, Path path) {
		}

		record Tile(long x, long y, int zoom) {
			static Tile of(String value) {
				var values = value.split(",");
				return new Tile(Long.parseLong(values[0]), Long.parseLong(values[1]), Integer.parseInt(values[2]));
			}
		}

		private final static int[] DX = {1, 0, -1, 0};
		private final static int[] DY = {0, 1, 0, -1};

		private final Map<String, Path> allGpxFiles;

		private final Connection connection;

		private final int zoom;

		static Tiles of(Path tracksDir, Path database, int zoom) throws IOException, SQLException {
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
				return new Tiles(allGpxFiles, connection, zoom);
			}
		}

		private Tiles(Map<String, Path> allGpxFiles, Connection connection, int zoom) {
			this.allGpxFiles = allGpxFiles;
			this.connection = connection;
			this.zoom = zoom;
		}

		public void update() throws Exception {
			this.processNewActivities();
			this.findClusters();
			this.findSquares();
		}

		@Override
		public void close() throws Exception {
			if (this.connection != null) {
				this.connection.close();
			}
		}

		private void processNewActivities() throws SQLException, IOException {

			var files = findUnprocessedActivities();
			var query = """
				WITH meta AS (
				    SELECT ? AS zoom, ? AS garmin_id
				),
				new_tiles AS (
				    SELECT DISTINCT meta.garmin_id, f_get_tile_number(geom, meta.zoom) AS tile
				    FROM st_read(?, layer = 'track_points'), meta
				)
				INSERT INTO tiles BY NAME
				SELECT tile.x,
				       tile.y,
				       tile.zoom,
				       f_make_tile(tile) AS geom,
				       1 AS visited_count,
				       started_on::date AS visited_first_on,
				       started_on::date AS visited_last_on,
				FROM new_tiles JOIN garmin_activities USING(garmin_id)
				ON CONFLICT DO UPDATE SET
				    visited_count = visited_count + 1,
				    visited_first_on = least(visited_first_on, excluded.visited_first_on),
				    visited_last_on = greatest(visited_last_on, excluded.visited_last_on);
				""";

			// Create or update tiles
			var tmpFiles = new ArrayList<Path>();
			try {
				try (var stmt = connection.prepareStatement(query)) {
					for (var file : files) {
						var tmp = Files.createTempFile("create-tiles-", ".gpx");
						try (var gis = new GZIPInputStream(new FileInputStream(file.path().toFile()))) {
							Files.copy(gis, tmp, StandardCopyOption.REPLACE_EXISTING);
						}
						stmt.setInt(1, this.zoom);
						stmt.setLong(2, file.id());
						stmt.setString(3, tmp.toString());
						tmpFiles.add(tmp);
						stmt.addBatch();
					}
					stmt.executeBatch();
				}

				// Mark activities as processed
				try (var stmt = connection.prepareStatement("INSERT INTO processed_zoom_levels(garmin_id, zoom) VALUES(?, ?)")) {
					for (var file : files) {
						stmt.setLong(1, file.id());
						stmt.setInt(2, this.zoom);
						stmt.addBatch();
					}
					stmt.executeBatch();
				}
				connection.commit();
			} finally {
				for (Path tmpFile : tmpFiles) {
					Files.deleteIfExists(tmpFile);
				}
			}
		}

		private Set<IdAndPath> findUnprocessedActivities() throws SQLException {
			try (
				var stmt = connection.prepareStatement("""
					SELECT g.garmin_id
					FROM garmin_activities g ANTI JOIN processed_zoom_levels z ON g.garmin_id = z.garmin_id AND z.zoom = ?
					WHERE gpx_available AND activity_type <> 'virtual_ride'
					ORDER BY started_on DESC""")
			) {
				stmt.setInt(1, this.zoom);
				try (var result = stmt.executeQuery()) {
					var unprocessedActivities = new HashSet<IdAndPath>();
					while (result.next()) {
						var id = result.getLong(1);
						var path = allGpxFiles.get(id + ".gpx.gz");
						if (path != null) {
							unprocessedActivities.add(new IdAndPath(id, path));
						}
					}
					return unprocessedActivities;
				}
			}
		}

		private void findClusters() throws SQLException {

			var tiles = new LinkedHashSet<Tile>();
			try (var stmt = connection.prepareStatement("SELECT x, y, zoom FROM tiles WHERE zoom = ? ORDER BY x, y")) {
				stmt.setLong(1, this.zoom);
				try (var result = stmt.executeQuery()) {
					while (result.next()) {
						tiles.add(new Tile(result.getLong("x"), result.getLong("y"), result.getInt("zoom")));
					}
				}
			}
			var labels = findClusters0(tiles);
			var cnt = new AtomicInteger(1);
			var mapping = new HashMap<Integer, Integer>();

			// Make cluster index start at 1 and uniform
			labels.entrySet().stream().sorted(Map.Entry.comparingByValue())
				.forEach(e -> e.setValue(mapping.computeIfAbsent(e.getValue(), v -> cnt.getAndIncrement())));
			try (
				var stmt = connection.prepareStatement("UPDATE tiles SET cluster_index = ? WHERE x = ? AND y = ? AND zoom = ?")
			) {
				for (Tile tile : tiles) {
					stmt.setInt(1, labels.getOrDefault(tile, 0));
					stmt.setLong(2, tile.x());
					stmt.setLong(3, tile.y());
					stmt.setLong(4, tile.zoom());
					stmt.addBatch();
				}
				stmt.executeBatch();
			}
			connection.commit();
		}

		/**
		 * Depth first search implementation of "one component at a time", see
		 * <a href="https://en.wikipedia.org/wiki/Connected-component_labeling">Connected-component_labeling</a>.
		 *
		 * @param tiles the tiles to be labelled
		 * @return the new labels
		 */
		private static Map<Tile, Integer> findClusters0(LinkedHashSet<Tile> tiles) {
			int label = 0;
			var labels = new HashMap<Tile, Integer>();

			for (var tile : tiles) {
				if (!labels.containsKey(tile)) {
					dfs(tiles, labels, tile, ++label);
				}
			}
			return labels;
		}

		private static void dfs(LinkedHashSet<Tile> tiles, Map<Tile, Integer> labels, Tile currentTile, int currentLabel) {
			// already labeled or not touched
			if (labels.containsKey(currentTile) || !tiles.contains(currentTile)) {
				return;
			}

			// Check all for borders before marking (https://en.wikipedia.org/wiki/Pixel_connectivity) before including this tile
			for (int direction = 0; direction < 4; ++direction) {
				if (!tiles.contains(new Tile(currentTile.x() + DX[direction], currentTile.y() + DY[direction], currentTile.zoom()))) {
					return;
				}
			}

			// mark the tile
			labels.put(currentTile, currentLabel);

			// recursively mark the neighbors
			for (int direction = 0; direction < 4; ++direction) {
				dfs(tiles, labels, new Tile(currentTile.x() + DX[direction], currentTile.y() + DY[direction], currentTile.zoom()), currentLabel);
			}
		}

		private void findSquares() throws Exception {

			Map<Integer, List<Tile>> maxSquares;
			try (var stmt = connection.createStatement()) {
				stmt.executeUpdate("UPDATE tiles SET square = null WHERE zoom = %d".formatted(this.zoom));

				var result = stmt.executeQuery("SELECT count(distinct x) FROM tiles");
				result.next();
				var rows = result.getInt(1);
				result.close();

				result = stmt.executeQuery("""
					PIVOT (
						SELECT x, y, concat(x, ',', y, ',', zoom) as f FROM tiles WHERE zoom = %d
					) ON y using(any_value(f)) ORDER BY x
					""".formatted(zoom)); // Due to a restriction that PIVOT'ed statements might not have parameters
				var numColumns = result.getMetaData().getColumnCount();
				var matrix = new String[rows][numColumns];

				int row = 0;
				while (result.next()) {
					for (int col = 0; col < numColumns; ++col) {
						matrix[row][col] = result.getString(col + 1);
					}
					++row;
				}
				result.close();
				maxSquares = findSquares0(matrix);
			}

			try (var stmt = connection.prepareStatement("UPDATE tiles SET square = ? WHERE x = ? AND y = ? AND zoom = ?")) {
				for (Map.Entry<Integer, List<Tile>> entry : maxSquares.entrySet()) {
					Integer k = entry.getKey();
					List<Tile> v = entry.getValue();
					for (Tile tile : v) {
						stmt.setInt(1, k);
						stmt.setLong(2, tile.x());
						stmt.setLong(3, tile.y());
						stmt.setLong(4, tile.zoom());
						stmt.addBatch();
					}
				}
				stmt.executeBatch();
			}
			connection.commit();
		}

		/**
		 * From <a href="https://www.geeksforgeeks.org/maximum-size-sub-matrix-with-all-1s-in-a-binary-matrix">geeksforgeeks.org</a>
		 *
		 * @param mat the matrix that might contain squares
		 * @return a map containing the size of the biggest square and all starting points of such squares
		 */
		private static Map<Integer, List<Tile>> findSquares0(String[][] mat) {
			int n = mat.length, m = mat[0].length;
			int ans = 0;

			// Create 1d array
			int[] dp = new int[n + 1];

			// variable to store the value of
			// {i, j+1} as its value will be
			// lost while setting dp[i][j+1].
			int diagonal = 0;

			// Holder for all squares of a size found
			var answers = new TreeMap<Integer, List<Tile>>();

			// Traverse column by column
			for (int j = m - 1; j >= 0; j--) {
				for (int i = n - 1; i >= 0; i--) {
					int tmp = dp[i];

					// If square cannot be formed
					if (mat[i][j] == null) {
						dp[i] = 0;
					} else {
						dp[i] = 1 + Math.min(dp[i], Math.min(diagonal, dp[i + 1]));
					}
					diagonal = tmp;
					if (dp[i] > 0 && dp[i] >= ans) {
						ans = dp[i];
						var tile = Tile.of(mat[i][j]);
						// remove all starting point that are smaller
						answers.headMap(ans).clear();
						answers.computeIfAbsent(ans, k -> new ArrayList<>()).add(tile);
					}
				}
			}
			return answers;
		}
	}
}
