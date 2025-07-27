///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 24
//DEPS info.picocli:picocli:4.7.7
//DEPS org.jsoup:jsoup:1.21.1

import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.concurrent.Callable;
import java.util.regex.Pattern;

import org.jsoup.Jsoup;
import org.jsoup.nodes.Element;
import picocli.CommandLine;

@CommandLine.Command(name = "extract-image-pois", mixinStandardHelpOptions = true,
	description = "Extract data from galleries created with create_galleries.java.",
	subcommands = {CommandLine.HelpCommand.class})
public class extract_image_pois implements Callable<Integer> {

	@CommandLine.Parameters(index = "0", description = "Gallery folder to process")
	private Path galleryDir;

	public static void main(String... args) {
		int exitCode = new CommandLine(new extract_image_pois()).execute(args);
		System.exit(exitCode);
	}

	@Override
	public Integer call() throws Exception {

		var userDirectory = Path.of(System.getProperty("user.dir"));
		var galleryDirResolved = userDirectory.resolve(this.galleryDir);

		if (!Files.isDirectory(galleryDirResolved)) {
			System.err.println("Directory containing gallery not found: " + galleryDirResolved);
			return CommandLine.ExitCode.USAGE;
		}

		var year = galleryDirResolved.getFileName().toString();

		var indexHtml = galleryDirResolved.resolve("index.html");
		if (!Files.isRegularFile(indexHtml)) {
			System.err.println("No index.html in " + galleryDirResolved);
			return CommandLine.ExitCode.USAGE;
		}

		var indexCsv = galleryDirResolved.resolve("index.csv");

		var pattern = Pattern.compile("Taken at (?<lat>-?\\d+\\.\\d+), (?<long>-?\\d+\\.\\d+)");
		var doc = Jsoup.parse(indexHtml);
		var main = doc.body().getElementById("main");

		try (var out = new PrintWriter(Files.newBufferedWriter(indexCsv, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING))) {
			out.println("type,name,visited_on,link,link_type,longitude,latitude");

			for (Element element : main.getElementsByClass("thumb")) {
				var p = element.getElementsByTag("p").first();
				if (p == null) {
					continue;
				}
				var location = pattern.matcher(p.text().trim());
				if (!location.matches()) {
					continue;
				}
				var name = element.getElementsByTag("h2").first().text();
				var img = element.getElementsByTag("img").first();
				var link = "gallery/%s/%s".formatted(year, img.attribute("src").getValue());

				out.println("picture,%s,%s,%s,relative,%s,%s".formatted(name, name, link, location.group("long"), location.group("lat")));
			}
		}

		return CommandLine.ExitCode.OK;
	}
}
