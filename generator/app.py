from datetime import datetime

from flask import request
from flask_frozen import Freezer
from numpy import nan
from pathlib import Path
from PIL import ImageDraw, ImageFont
from sklearn.linear_model import LinearRegression
from sklearn.preprocessing import PolynomialFeatures
from staticmap import Line, StaticMap

import click
import duckdb
import flask
import functools
import gpxpy
import gzip
import jinja2.exceptions
import json
import pandas
import os


def site(database: str):
    db = duckdb.connect(database=database, read_only=True)
    max_garmin = None
    with db.cursor() as tl_con:
        tl_con.execute("INSTALL spatial")
        tl_con.execute("LOAD spatial")
        max_garmin = tl_con.execute('SELECT max(started_on) FROM garmin_activities').fetchone()[0]

    now = datetime.now()

    def fmt_sport(sport):
        match sport:
            case "cycling":
                return "🚴‍♂️"
            case "running":
                return "🏃‍♂️"
            case "swimming":
                return "🏊‍♂️"
            case _:
                return "??"

    app = flask.Flask(__name__, static_url_path="/")
    app.jinja_options["autoescape"] = lambda _: True
    app.jinja_options['extensions'] = ['jinja_markdown.MarkdownExtension']
    app.jinja_env.filters.update({
        'fmt_month': lambda v: v.strftime('%B %Y'),
        'fmt_date': lambda v: v.strftime('%Y-%m-%d') if not (v is None or v is pandas.NaT) else '',
        'fmt_time': lambda v: v.strftime('%H:%M'),
        'fmt_datetime': lambda v: v.strftime('%Y-%m-%dT%H:%M:%S'),
        'fmt_double': lambda v: format(v, '.2f'),
        'fmt_int': lambda v: format(v, '.0f'),
        'fmt_sport': fmt_sport
    })
    app.jinja_env.tests.update({
        'nat': lambda v: v is pandas.NaT
    })

    root = Path(__file__).parent
    assets_dir = root / app.static_folder / "assets"
    gallery_dir = root / app.static_folder / "gallery"
    gear_dir = root / app.template_folder / "gear"
    track_dir = root / "tracks"

    # For image generation
    font_attribution = ImageFont.truetype(root.joinpath("misc/FreeSans.ttf"), 12)
    font_label = ImageFont.truetype(root.joinpath("misc/FreeSans.ttf"), 36)
    font_data = ImageFont.truetype(root.joinpath("misc/FreeSansBold.ttf"), 48)
    env_var = dict(os.environ)
    api_key_key = 'THUNDERFOREST_API_KEY'
    app.jinja_env.globals.update({
        'tz': 'Europe/Berlin',
        'now': now,
        'max_year': 2024,
        'assets_present': assets_dir.is_dir(),
        'gallery_present': gallery_dir.is_dir(),
        'thunderforest_api_key': env_var[api_key_key] if api_key_key in env_var else None,
        'max_garmin': max_garmin if max_garmin is not None else now
    })

    @app.route('/')
    def index():
        with db.cursor() as con:
            summary = con.execute('FROM v_summary').df()
            longest_streak = con.execute('FROM v_longest_streak').fetchone()
            start_year = max_garmin.year if max_garmin is not None else now.year
            by_year_and_sport = con.execute('FROM v_distances_by_year_and_sport WHERE year = ?', [start_year]).df()
            activity_by_year = con.execute('FROM v_daily_activity_by_year WHERE year > ?', [start_year - 2]).df()

        return flask.render_template('index.html.jinja2', summary=summary, by_year_and_sport=by_year_and_sport,
                                     longest_streak=longest_streak, max_garmin=max_garmin,
                                     activity_by_year=activity_by_year)

    @app.route("/mileage/")
    def mileage():
        with db.cursor() as con:
            bikes = con.execute('FROM v_active_bikes').df()
            ytd_summary = db.execute('FROM v_ytd_summary').df()
            ytd_totals = db.execute('FROM v_ytd_totals').df()
            ytd_bikes_query = """
                SELECT * replace(strftime(month, '%B') AS month) 
                FROM (PIVOT (FROM v_ytd_bikes) ON bike USING first(value) ORDER by month)
            """
            ytd_bikes = db.execute(ytd_bikes_query).df().set_index('month').fillna(0)
            monthly_averages = db.execute('FROM v_monthly_average').df()

        return flask.render_template('mileage.html.jinja2', bikes=bikes, ytd_summary=ytd_summary, ytd_totals=ytd_totals,
                                     ytd_bikes=ytd_bikes, monthly_averages=monthly_averages)

    @app.route("/achievements/")
    def achievements():
        max_year = flask.current_app.jinja_env.globals.get('max_year')
        with db.cursor() as con:
            reoccurring_events = con.execute('FROM v_reoccurring_events').fetchall()
            one_time_only_events = con.execute('FROM v_one_time_only_events').df().replace({nan: None})
            pace_percentiles = con.execute(
                'FROM v_pace_percentiles_per_distance_and_year_seconds WHERE distance <> ? AND year <= ?',
                ['Marathon', max_year]).df()

        def pivot(distance, data):
            percentiles = data.loc[data['distance'] == distance]['percentiles']
            years = zip(*functools.reduce(lambda x, y: x + [y], percentiles, []))
            return list(years)

        development = {
            'years': pace_percentiles['year'].unique().tolist(),
            'percentiles': {
                '5k': pivot('5', pace_percentiles),
                '10k': pivot('10', pace_percentiles),
                '21k': pivot('21', pace_percentiles)
            }
        }

        return flask.render_template('achievements.html.jinja2', reoccuring_events=reoccurring_events,
                                     one_time_only_events=one_time_only_events, development=development)

    def gear_template(name: str):
        """Normalizes the name into the gear folder, throwing on attempted path traversal"""
        return gear_dir.joinpath(name + ".html.jinja2").resolve().relative_to(gear_dir)

    @app.route("/gear/")
    @app.route("/gear/<name>/")
    def gear(name: str = None):
        if name is not None and not gear_dir.is_dir():
            flask.abort(404)
        if name is not None:
            try:
                template = gear_template(name)
                with db.cursor() as con:
                    bike = con.execute('FROM v_bikes WHERE name = ?', [name]).df()
                    mileage_by_year = con.execute('FROM v_mileage_by_bike_and_year WHERE name = ?', [name]).df()
                    maintenance = con.execute('FROM v_maintenances WHERE name = ?', [name]).df()
                    specs = con.execute('FROM v_specs WHERE name = ?', [name]).df()

                x = mileage_by_year['year'].to_numpy().reshape(-1, 1)
                y = mileage_by_year['mileage'].to_numpy()

                x = PolynomialFeatures(degree=3, include_bias=False).fit_transform(x)
                model = LinearRegression()
                model.fit(x, y)
                trend = model.predict(x)

                return flask.render_template((gear_dir.parts[-1] / template).as_posix(), bike=bike,
                                             mileage_by_year=mileage_by_year, pd=pandas, trend=trend,
                                             maintenance=maintenance, specs=specs)
            except (ValueError, jinja2.exceptions.TemplateNotFound):
                flask.abort(404)

        with db.cursor() as con:
            bikes = con.execute('FROM v_bikes').df()
            shoes = con.execute('FROM v_shoes').df()
        if gear_dir.is_dir():
            bikes['has_details'] = bikes['name'].map(lambda n: gear_dir.joinpath(gear_template(n)).is_file())

        return flask.render_template('gear.html.jinja2', bikes=bikes, shoes=shoes)

    @app.route("/history/")
    def history():
        return flask.render_template('history.html.jinja2')

    @app.route("/explorer/<zoom>/<feature_type>.json", )
    def explorer_json(zoom: str, feature_type: str):
        if feature_type not in ['clusters', 'tiles', 'squares']:
            flask.abort(404)

        try:
            zoom = int(zoom)
        except ValueError:
            flask.abort(404)

        if zoom not in [14, 17]:
            flask.abort(404)

        with db.cursor() as con:
            result = con.execute("SELECT feature_collection FROM query_table(?) WHERE zoom = ?",
                                 ['v_explorer_' + feature_type, zoom]).fetchone()
            return [] if result is None else result[0], {'content-type': 'application/json'}

    @app.route("/explorer/fries.json")
    def fries():
        with db.cursor() as con:
            result = con.execute("SELECT feature_collection FROM v_fries").fetchone()
            return [] if result is None else result[0], {'content-type': 'application/json'}

    @app.route("/explorer/", )
    def explorer():
        thunderforest_api_key = flask.current_app.jinja_env.globals.get('thunderforest_api_key')
        with db.cursor() as con:
            result = con.execute("FROM v_explorer_areas").fetchone()
            areas = [] if result is None else result[0]
            summary = con.execute("FROM v_explorer_summary WHERE zoom = 14").df()
            return flask.render_template('explorer.html.jinja2', summary=summary, areas=json.loads(areas),
                                         thunderforest_api_key=thunderforest_api_key, max_garmin=max_garmin)

    @app.route("/unexplored", methods=['POST'])
    def export_unexplored():

        sw = request.form.get("sw")
        ne = request.form.get("ne")
        zoom = request.form.get("zoom")

        if sw is None or ne is None or zoom is None or not zoom.isnumeric():
            flask.abort(404)

        with db.cursor() as con:
            # Funny enough, DuckDB is unhappy without having at least one explicit cast to VARCHAR, and
            # fails me with "Invalid Input Error: ST_GeomFromText requires a string argument"
            result = con.execute(
                "SELECT f_unexplored_tiles(ST_GeomFromText(?::VARCHAR), ST_GeomFromText(?::VARCHAR), ?::INT)",
                [sw, ne, zoom]).fetchone()
        return [] if result is None else result[0], {'content-type': 'application/json',
                                                     'Content-Disposition': 'attachment; filename="unexplored.json"'}

    @app.route("/map/<activity_id>.png")
    def activity_map(activity_id: int):

        thunderforest_api_key = flask.current_app.jinja_env.globals.get('thunderforest_api_key')
        if thunderforest_api_key is None:
            url_template = 'https://a.tile.openstreetmap.org/{z}/{x}/{y}.png'
        else:
            url_template = 'https://tile.thunderforest.com/atlas/{z}/{x}/{y}.png?apikey=' + thunderforest_api_key

        gpx_file = track_dir.joinpath(f'{activity_id}.gpx.gz')
        if not gpx_file.is_file():
            flask.abort(404)

        filename = track_dir.joinpath(f'{activity_id}.png')
        if not filename.is_file():
            map_data = []
            with gzip.open(gpx_file) as handle:
                gpx = gpxpy.parse(handle.read())
                for track in gpx.tracks:
                    for segment in track.segments:
                        for point in segment.points:
                            map_data.append([point.longitude, point.latitude])
            line = Line(map_data, '#CD5C5C', 4)
            m = StaticMap(1000, 1000, 10, 0, url_template)
            m.add_line(line)
            image = m.render()

            d = ImageDraw.Draw(image)

            margin = 20
            margin_top_label = image.height - margin - font_data.size - font_label.size * 1.25
            margin_top_value = image.height - margin - font_data.size

            font_fill = '#778899'
            strokeFill = '#FFF'

            with db.cursor() as con:
                details = con.execute('FROM v_activity_details WHERE id = ?', [activity_id]).fetchone()
                cols = [col[0] for col in con.description]

                for i, label in enumerate(
                        [details[cols.index('activity_type')].title(), "Elevation gain", "Pace", "Duration"]):
                    d.text((margin + i * 250, margin_top_label), label, font=font_label, fill=font_fill, stroke_width=1,
                           stroke_fill=strokeFill)

                d.text((margin, margin), details[cols.index('name')], font=font_data, fill=font_fill, stroke_width=1,
                       stroke_fill=strokeFill)
                d.text((margin, margin_top_value), str(details[cols.index('distance')]) + "km", font=font_data,
                       fill=font_fill, stroke_width=1, stroke_fill=strokeFill)
                d.text((margin + 250, margin_top_value), str(details[cols.index('elevation_gain')]) + "m",
                       font=font_data, fill=font_fill, stroke_width=1, stroke_fill=strokeFill)
                d.text((margin + 500, margin_top_value), details[cols.index('pace')] + "/km", font=font_data,
                       fill=font_fill, stroke_width=1, stroke_fill=strokeFill)
                d.text((margin + 750, margin_top_value), details[cols.index('duration')], font=font_data,
                       fill=font_fill,
                       stroke_width=1, stroke_fill=strokeFill)
                if thunderforest_api_key is not None:
                    d.text((margin + 2, image.height - margin + 2),
                           'Maps © Thunderforest, Data © OpenStreetMap contributors',
                           font=font_attribution, fill=font_fill, stroke_width=1,
                           stroke_fill=strokeFill)

            image.save(filename)

        return flask.send_file(filename, mimetype='image/png')

    return app


@click.group()
def cli():
    pass


@cli.command()
@click.argument('database', type=click.Path(exists=True), default='../sport.db')
def run(database: str):
    """Runs the site in development mode"""
    site(database).run(debug=True)


@cli.command()
@click.argument('database', type=click.Path(exists=True))
@click.argument('destination', type=click.Path(file_okay=False, resolve_path=True))
@click.option('--base-url', default='https://biking.michael-simons.eu')
def build(database: str, destination: str, base_url: str):
    """Builds the site"""
    app = site(database)
    app.config['FREEZER_DESTINATION'] = destination
    app.config['FREEZER_BASE_URL'] = base_url
    freezer = Freezer(app)
    freezer.freeze()


if __name__ == '__main__':
    cli()
