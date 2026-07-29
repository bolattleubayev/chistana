using Toybox.Application as Application;
using Toybox.WatchUi as WatchUi;
using Toybox.Graphics as Graphics;
using Toybox.System as System;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;
using Toybox.Activity as Activity;
using Toybox.ActivityMonitor as ActivityMonitor;
using Toybox.Weather as Weather;
using Toybox.Complications as Complications;
using Toybox.Math as Math;
using Toybox.Timer as Timer;
import Toybox.Lang;

// ── Palette (measured from the mockups/extracted art) ───────────────────
const COLOR_NAVY      = 0x0C4A82; // ring band, battery icon, dividers, stat text
const COLOR_SKY_DAY   = 0xACDFFC;
const COLOR_SKY_NIGHT = 0x00285A;
const MISSING_VALUE   = "--";
const MISSING_TEMP_STR = MISSING_VALUE + "°C";

// ── Time glyphs: single shared set (styling is baked into the art) ──────
// Ink measurements below come straight from tools/scripts/extract_digits.py's
// printed bboxes on a 100px-tall canvas (TARGET_H) - same technique Kadi
// uses for its own digit tables.
const GLYPH_CANVAS_H = 100;
const DIGIT_INK_W    = [85, 57, 79, 81, 87, 80, 82, 77, 84, 82];
const DIGIT_PAD_LEFT = [2, 2, 2, 2, 2, 2, 2, 2, 2, 2];
const COLON_INK_W    = 44;
const COLON_PAD_LEFT = 3;
const TIME_DIGIT_GAP = 4;
const TIME_COLON_GAP = 8;
const TIME_SCALE     = 0.79; // shrinks the glyph set so it clears the ring above/stats below
const COLON_HEIGHT_FRAC = 0.67; // colon renders at 67% of the digits' height

// Ring name text ("KADISHA" / "MUKHAMEDJANOVA", see drawArcText) - letters
// are extracted at a fixed 48px height (see tools/scripts/extract_letters.py)
// and scaled down to this on-screen height, small enough to sit inside the
// ring band without its top/bottom edges poking past the band's own width.
const LETTER_TARGET_H = 19;

// Weekday/month names for the date line - module-level consts so the daily
// cache refresh (see updateMoonPhase) doesn't allocate fresh arrays every
// time it runs. Gregorian.info's day_of_week is 1-indexed (1=Sunday..
// 7=Saturday, NOT 0-indexed) - indexing this 7-element array with the raw
// value crashes with an out-of-bounds error on Saturdays, so callers must
// always subtract 1 first.
const WEEKDAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTH_NAMES   = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// ── Weather condition -> visual bucket ───────────────────────────────────
const BUCKET_CLEAR   = 0;
const BUCKET_PARTLY  = 1;
const BUCKET_CLOUDY  = 2;
const BUCKET_RAIN    = 3;
const BUCKET_SNOW    = 4;
const BUCKET_THUNDER = 5;

// ── Precipitation animation (values ported from Kadi's drawPrecip, already
// tuned there) - falling motion comes from System.getTimer() wrapped to one
// tile height, not a per-frame random jump, so it reads as falling rather
// than shivering in place whenever onUpdate happens to redraw. ───────────
const RAIN_DRIFT_RATIO     = 0.25; // ~tan(14 deg), matches the streak angle baked into the art
const RAIN_FALL_MS         = 1800;
const SNOW_FALL_MS         = 5000;
const SNOW_SWAY_PERIOD_MS  = 3400;
const SNOW_SWAY_PX         = 10;
const CLOUD_DENSE_SCALE    = 1.3; // CLOUDY/RAIN/SNOW/THUNDER cloud scale-up vs. PARTLY
const THUNDER_FLASH_PERIOD_MS   = 4000;
const THUNDER_FLASH_DURATION_MS = 120;

// ── Sun/moon arc across the sky ──────────────────────────────────────────
// Horizontal sweep and the low (rise/set) point of the parabola, as
// fractions of screen width/height - tuned so the peak clears the ring's
// clip boundary and the low points sit just above the skyline/clouds.
const CELESTIAL_ARC_X0     = 0.16;
const CELESTIAL_ARC_X1     = 0.84;
// The frac=0.5 peak lands at x=center, which is exactly where the white
// "smile" cutout (see onLayout's mHorizonCircleCy/R) reaches its deepest
// point - drawScene re-fills that white smile on top of the celestial
// bitmap (to fix precip bleeding into the curve's corners, see drawScene),
// so if the peak isn't kept well below mYHorizon, that re-fill paints over
// the sun/moon's top edge instead of just clipping it. LOW_FRAC - HEIGHT_FRAC
// (the peak's offset below mYHorizon) needs to clear at least half the
// celestial bitmap's height (~56-60px tall, so ~30px) - verified in-simulator
// rather than derived purely from the mockup's proportions.
const CELESTIAL_ARC_LOW_FRAC  = 0.20; // below mYHorizon, at frac=0/1 (rise/set)
const CELESTIAL_ARC_HEIGHT_FRAC = 0.09; // rise from the low point up to the frac=0.5 peak

// While the watch is awake (screen actively on, not sleeping/AOD), a Timer
// drives requestUpdate() at this interval so the seconds marker sweeps
// smoothly instead of only moving once/second - the platform default
// onUpdate cadence. Only runs while awake (started in onShow/onExitSleep,
// stopped in onHide/onEnterSleep) so it doesn't burn battery drawing the
// full scene 20x/sec while the display is off or dimmed.
const SECONDS_TIMER_INTERVAL_MS = 50;

// How often the cached static-scene buffer (see mStaticBuffer) is actually
// re-rendered - once/sec is plenty since nothing in that layer (time/date/
// battery/stats/weather/ring-text) changes faster than that; only the
// seconds marker itself needs to move on every SECONDS_TIMER_INTERVAL_MS tick.
const STATIC_REFRESH_INTERVAL_MS = 1000;

class ChistanaApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new ChistanaView()];
    }
}

class ChistanaView extends WatchUi.WatchFace {
    // Digit/glyph bitmaps
    private var mDigits as Array<Graphics.BitmapType>?;         // array of 10 bitmaps, index = digit value
    private var mColon;
    private var mIconStar;
    private var mIconSeconds;
    private var mLetters as Dictionary<String, Graphics.BitmapType>?;        // single-char uppercase String -> bitmap
    private var mWeatherIcons as Array<Graphics.BitmapType>?;   // array indexed by BUCKET_*
    private var mSun;
    private var mMoonPhases as Array<Graphics.BitmapType>?;     // array of 8 bitmaps
    private var mStars;
    private var mDayClouds as Array<Graphics.BitmapType>?;      // array of 5 bitmaps
    private var mNightClouds as Array<Graphics.BitmapType>?;    // array of 5 bitmaps
    private var mDaySkyline;
    private var mNightSkyline;
    private var mRainTiles as Array<Graphics.BitmapType>?;      // array of 3 bitmaps
    private var mSnowTiles as Array<Graphics.BitmapType>?;      // array of 3 bitmaps

    // Complication-backed values
    private var mSunriseSec = null;
    private var mSunsetSec = null;
    private var mWeeklyDistanceM = null;
    private var mSunriseId;
    private var mSunsetId;
    private var mWeeklyDistId;

    // Moon phase and date string, both cached per calendar day (see
    // updateMoonPhase) since they only change once a day.
    private var mMoonCacheKey = null;
    private var mMoonPhaseIndex = 4; // default to full moon until first computed
    private var mDateStr = "";

    // Seconds-marker phase lock: Toybox.System has no sub-second clock
    // read, so there's no true sub-second tick to read directly - instead,
    // the moment clockTime.sec is observed to change, the current
    // getTimer() value is snapshotted as that second's zero point, and
    // every subsequent onUpdate (even within the same second) measures
    // elapsed ms against that snapshot. This keeps the marker's angle a
    // genuinely continuous function of time synced to the real clock,
    // rather than quantized to 60 fixed tick positions. Combined with
    // mSecondsTimer below (which forces onUpdate to run several times a
    // second while awake), this is what makes the sweep look smooth rather
    // than just "correctly positioned once/second".
    private var mLastSec = null;
    private var mLastSecTimerMs = 0;

    // Drives requestUpdate() at SECONDS_TIMER_INTERVAL_MS while awake, so
    // the full scene (and the seconds marker within it) redraws faster than
    // the platform's default ~once/second cadence. Only ever running while
    // the display is actually on - see onShow/onHide/onExitSleep/onEnterSleep.
    private var mSecondsTimer;

    // Everything in the scene EXCEPT the seconds marker and weather badge
    // (face base, sky/clouds/precip/skyline, battery, date, time, stats,
    // ring + ring-text) is cached here and only re-rendered once/sec (see
    // STATIC_REFRESH_INTERVAL_MS), not on every SECONDS_TIMER_INTERVAL_MS
    // tick - redrawing that whole layer (34 rotated ring-text glyphs via
    // AffineTransform, precip tile loops, etc.) 20x/sec was cheap enough on
    // the desktop simulator to look smooth but was the actual cause of
    // stutter on real hardware, whose CPU has a far tighter per-frame
    // budget. Fast ticks now just blit this cached bitmap and draw the
    // marker/badge on top, matching their original draw order (marker
    // before badge, so the badge still visually covers the marker during
    // its ~6 o'clock pass - see drawWeatherBadge/drawSecondsMarker).
    private var mStaticBuffer;
    private var mLastStaticRefreshMs = null;
    private var mCachedBucket = BUCKET_CLEAR;
    private var mCachedTempStr = MISSING_TEMP_STR;

    // VectorFont lookups loaded once in onLayout instead of re-fetched on
    // every static-buffer refresh (still up to once/sec, indefinitely, for
    // as long as the watch face is showing) - same "RobotoCondensedRegular"
    // face at each of these 5 fixed sizes throughout the face, so there's
    // nothing to invalidate/reload later.
    private var mFontBattery;
    private var mFontDate;
    private var mFontStatValue;
    private var mFontStatLabel;
    private var mFontBadge;

    // Layout, cached in onLayout
    private var mCenterX;
    private var mCenterY;
    private var mRadius;
    private var mRingPen;
    private var mRingRadius;
    private var mStarSize;
    private var mYBattery;
    private var mYDate;
    private var mYTime;
    private var mYStats;
    private var mYHorizon;
    private var mYHorizonClipTop;
    private var mHorizonCircleCy; // center of the big "smile" circle used to curve the horizon
    private var mHorizonCircleR;
    private var mYBadgeCenter;
    private var mBadgeRadius;
    private var mStatColX as Array<Number>?; // [left, center, right]

    function initialize() {
        WatchFace.initialize();
    }

    // The smooth seconds-sweep timer only runs while the screen is actually
    // on - onShow/onExitSleep both fire when that becomes true, onHide/
    // onEnterSleep when it stops, so it never burns extra battery redrawing
    // the full scene while the display is off or in low-power AOD.
    function onShow() as Void {
        startSecondsTimer();
    }

    function onHide() as Void {
        stopSecondsTimer();
    }

    function onExitSleep() as Void {
        startSecondsTimer();
    }

    function onEnterSleep() as Void {
        stopSecondsTimer();
    }

    private function startSecondsTimer() as Void {
        if (mSecondsTimer == null) {
            mSecondsTimer = new Timer.Timer();
        }
        mSecondsTimer.start(method(:onSecondsTick), SECONDS_TIMER_INTERVAL_MS, true);
    }

    private function stopSecondsTimer() as Void {
        if (mSecondsTimer != null) {
            mSecondsTimer.stop();
        }
    }

    function onSecondsTick() as Void {
        WatchUi.requestUpdate();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        mDigits = [
            WatchUi.loadResource(Rez.Drawables.digit_0),
            WatchUi.loadResource(Rez.Drawables.digit_1),
            WatchUi.loadResource(Rez.Drawables.digit_2),
            WatchUi.loadResource(Rez.Drawables.digit_3),
            WatchUi.loadResource(Rez.Drawables.digit_4),
            WatchUi.loadResource(Rez.Drawables.digit_5),
            WatchUi.loadResource(Rez.Drawables.digit_6),
            WatchUi.loadResource(Rez.Drawables.digit_7),
            WatchUi.loadResource(Rez.Drawables.digit_8),
            WatchUi.loadResource(Rez.Drawables.digit_9),
        ];
        mColon = WatchUi.loadResource(Rez.Drawables.colon);
        mIconStar = WatchUi.loadResource(Rez.Drawables.icon_star);
        mIconSeconds = WatchUi.loadResource(Rez.Drawables.icon_seconds);
        mLetters = {
            "A" => WatchUi.loadResource(Rez.Drawables.letter_a),
            "C" => WatchUi.loadResource(Rez.Drawables.letter_c),
            "D" => WatchUi.loadResource(Rez.Drawables.letter_d),
            "E" => WatchUi.loadResource(Rez.Drawables.letter_e),
            "G" => WatchUi.loadResource(Rez.Drawables.letter_g),
            "H" => WatchUi.loadResource(Rez.Drawables.letter_h),
            "I" => WatchUi.loadResource(Rez.Drawables.letter_i),
            "J" => WatchUi.loadResource(Rez.Drawables.letter_j),
            "K" => WatchUi.loadResource(Rez.Drawables.letter_k),
            "M" => WatchUi.loadResource(Rez.Drawables.letter_m),
            "N" => WatchUi.loadResource(Rez.Drawables.letter_n),
            "O" => WatchUi.loadResource(Rez.Drawables.letter_o),
            "S" => WatchUi.loadResource(Rez.Drawables.letter_s),
            "T" => WatchUi.loadResource(Rez.Drawables.letter_t),
            "U" => WatchUi.loadResource(Rez.Drawables.letter_u),
            "V" => WatchUi.loadResource(Rez.Drawables.letter_v),
        };
        mWeatherIcons = [
            WatchUi.loadResource(Rez.Drawables.weather_sunny),
            WatchUi.loadResource(Rez.Drawables.weather_partly_cloudy),
            WatchUi.loadResource(Rez.Drawables.weather_cloudy),
            WatchUi.loadResource(Rez.Drawables.weather_rain),
            WatchUi.loadResource(Rez.Drawables.weather_snow),
            WatchUi.loadResource(Rez.Drawables.weather_thunder),
        ];
        mSun = WatchUi.loadResource(Rez.Drawables.sun);
        mMoonPhases = [
            WatchUi.loadResource(Rez.Drawables.moon_phase_0),
            WatchUi.loadResource(Rez.Drawables.moon_phase_1),
            WatchUi.loadResource(Rez.Drawables.moon_phase_2),
            WatchUi.loadResource(Rez.Drawables.moon_phase_3),
            WatchUi.loadResource(Rez.Drawables.moon_phase_4),
            WatchUi.loadResource(Rez.Drawables.moon_phase_5),
            WatchUi.loadResource(Rez.Drawables.moon_phase_6),
            WatchUi.loadResource(Rez.Drawables.moon_phase_7),
        ];
        mStars = WatchUi.loadResource(Rez.Drawables.stars);
        mDayClouds = [
            WatchUi.loadResource(Rez.Drawables.day_cloud_1),
            WatchUi.loadResource(Rez.Drawables.day_cloud_2),
            WatchUi.loadResource(Rez.Drawables.day_cloud_3),
            WatchUi.loadResource(Rez.Drawables.day_cloud_4),
            WatchUi.loadResource(Rez.Drawables.day_cloud_5),
        ];
        mNightClouds = [
            WatchUi.loadResource(Rez.Drawables.night_cloud_1),
            WatchUi.loadResource(Rez.Drawables.night_cloud_2),
            WatchUi.loadResource(Rez.Drawables.night_cloud_3),
            WatchUi.loadResource(Rez.Drawables.night_cloud_4),
            WatchUi.loadResource(Rez.Drawables.night_cloud_5),
        ];
        mDaySkyline = WatchUi.loadResource(Rez.Drawables.day_skyline);
        mNightSkyline = WatchUi.loadResource(Rez.Drawables.night_skyline);
        mRainTiles = [
            WatchUi.loadResource(Rez.Drawables.rain_tile_1),
            WatchUi.loadResource(Rez.Drawables.rain_tile_2),
            WatchUi.loadResource(Rez.Drawables.rain_tile_3),
        ];
        mSnowTiles = [
            WatchUi.loadResource(Rez.Drawables.snow_tile_1),
            WatchUi.loadResource(Rez.Drawables.snow_tile_2),
            WatchUi.loadResource(Rez.Drawables.snow_tile_3),
        ];

        mSunriseId = new Complications.Id(Complications.COMPLICATION_TYPE_SUNRISE);
        mSunsetId = new Complications.Id(Complications.COMPLICATION_TYPE_SUNSET);
        mWeeklyDistId = new Complications.Id(Complications.COMPLICATION_TYPE_WEEKLY_RUN_DISTANCE);
        Complications.registerComplicationChangeCallback(method(:onComplicationChange));
        Complications.subscribeToUpdates(mSunriseId);
        Complications.subscribeToUpdates(mSunsetId);
        Complications.subscribeToUpdates(mWeeklyDistId);
        refreshComplicationValue(mSunriseId);
        refreshComplicationValue(mSunsetId);
        refreshComplicationValue(mWeeklyDistId);

        var w = dc.getWidth();
        var h = dc.getHeight();
        mCenterX = (w / 2).toNumber();
        mCenterY = (h / 2).toNumber();
        var minWH = w < h ? w : h;
        mRadius = (minWH / 2).toNumber();

        // Ring is sized off the star, not the other way around, so it comes
        // out "barely wider than the stars" instead of an arbitrary fraction
        // of screen width. Centerline is pushed 2px past the true edge (not
        // pulled in) so the stroke's outer edge fully covers the display's
        // round edge instead of leaving a hairline of background visible.
        mStarSize = (w * 0.062).toNumber();
        mRingPen = mStarSize + 6;
        mRingRadius = mRadius - (mRingPen / 2).toNumber() + 2;

        mYBattery = (h * 0.115).toNumber();
        mYDate = (h * 0.185).toNumber();
        mYTime = (h * 0.315).toNumber();
        mYStats = (h * 0.45).toNumber();
        mYHorizon = (h * 0.57).toNumber();
        mYBadgeCenter = (h * 0.91).toNumber();
        mBadgeRadius = (w * 0.075).toNumber();
        mStatColX = [(w * 0.21).toNumber(), (w * 0.50).toNumber(), (w * 0.79).toNumber()];

        // Horizon "smile" curve: a big circle centered well above the screen,
        // whose bottom arc passes through mYHorizon at the center and rises
        // HORIZON_RISE px higher at the ring's edge - deepest (safest, most
        // white clearance) exactly where the stats row content sits, curving
        // up only at the sides where there's no foreground content to clip.
        var rise = 32.0;
        var maxDx = mRadius.toFloat();
        mHorizonCircleR = (maxDx * maxDx + rise * rise) / (2.0 * rise);
        mHorizonCircleCy = mYHorizon - mHorizonCircleR;
        mYHorizonClipTop = (mYHorizon - rise - 4).toNumber();

        mFontBattery = Graphics.getVectorFont({:face => "RobotoCondensedRegular", :size => 30});
        mFontDate = Graphics.getVectorFont({:face => "RobotoCondensedRegular", :size => 32});
        mFontStatValue = Graphics.getVectorFont({:face => "RobotoCondensedRegular", :size => 40});
        mFontStatLabel = Graphics.getVectorFont({:face => "RobotoCondensedRegular", :size => 28});
        mFontBadge = Graphics.getVectorFont({:face => "RobotoCondensedRegular", :size => 26});

        // May return null on very memory-constrained devices - onUpdate
        // falls back to drawing the static layer straight to the real dc
        // every tick (the old, slower behavior) if so, rather than crashing.
        var bufRef = Graphics.createBufferedBitmap({:width => w, :height => h});
        mStaticBuffer = (bufRef != null) ? bufRef.get() : null;
    }

    function onComplicationChange(id as Complications.Id) as Void {
        refreshComplicationValue(id);
        WatchUi.requestUpdate();
    }

    private function refreshComplicationValue(id as Complications.Id) as Void {
        try {
            var complication = Complications.getComplication(id);
            var value = complication.value;
            if (value == null) {
                return;
            }
            var t = id.getType();
            if (t == Complications.COMPLICATION_TYPE_SUNRISE) {
                mSunriseSec = value;
            } else if (t == Complications.COMPLICATION_TYPE_SUNSET) {
                mSunsetSec = value;
            } else if (t == Complications.COMPLICATION_TYPE_WEEKLY_RUN_DISTANCE) {
                mWeeklyDistanceM = value;
            }
        } catch (ex) {
            // Leave cached value as-is if the complication isn't available yet.
        }
    }

    // ── Moon phase (Conway's algorithm) + date string, both cached per ──
    // calendar day off one Gregorian.info() call, since neither changes
    // more than once a day.
    private function updateMoonPhase() as Void {
        var d = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var key = d.year * 10000 + d.month * 100 + d.day;
        if (key == mMoonCacheKey) {
            return;
        }
        mMoonCacheKey = key;

        // day_of_week is 1-indexed (1=Sunday..7=Saturday) - subtract 1
        // before indexing WEEKDAY_NAMES or Saturday (7) reads past the end
        // of the 7-element (0-6) array.
        mDateStr = WEEKDAY_NAMES[d.day_of_week - 1] + ", " + MONTH_NAMES[d.month - 1] + " " + d.day;

        var year = d.year;
        var month = d.month;
        var day = d.day;
        if (month < 3) {
            year -= 1;
            month += 12;
        }
        month += 1;

        // c and e must stay Float here - truncating them before summing
        // (as an earlier version did) throws away up to ~1 day of the
        // running total and can nudge the result across a phase boundary.
        var c = 365.25 * year;
        var e = 30.6 * month;
        // Epoch constant tuned against the true synodic period (fit to
        // minimize bucket-boundary error over a year of dates) - the
        // textbook 694039.09 value ran the visible phase about 3/4 of a
        // day ahead of the real moon.
        var jd = c + e + day - 694039.77;
        jd = jd / 29.5305882;
        var whole = jd.toNumber();
        var frac = jd - whole;
        if (frac < 0) {
            frac += 1.0;
        }
        var idx = (frac * 8 + 0.5).toNumber() % 8;
        if (idx < 0) {
            idx += 8;
        }
        mMoonPhaseIndex = idx;
    }

    // ── Weather condition -> visual bucket ───────────────────────────────
    // Each bucket gets its own dial scene (see drawClouds/drawPrecip) as
    // well as its own weather-badge icon.
    private function mapCondition(condition) as Number {
        if (condition == null) {
            return BUCKET_CLEAR;
        }
        switch (condition) {
            case Weather.CONDITION_CLEAR:
            case Weather.CONDITION_FAIR:
                return BUCKET_CLEAR;

            case Weather.CONDITION_PARTLY_CLOUDY:
            case Weather.CONDITION_PARTLY_CLEAR:
            case Weather.CONDITION_MOSTLY_CLEAR:
            case Weather.CONDITION_THIN_CLOUDS:
                return BUCKET_PARTLY;

            case Weather.CONDITION_MOSTLY_CLOUDY:
            case Weather.CONDITION_CLOUDY:
            case Weather.CONDITION_FOG:
            case Weather.CONDITION_HAZY:
            case Weather.CONDITION_HAZE:
            case Weather.CONDITION_MIST:
            case Weather.CONDITION_DUST:
            case Weather.CONDITION_SMOKE:
            case Weather.CONDITION_SAND:
            case Weather.CONDITION_SANDSTORM:
            case Weather.CONDITION_VOLCANIC_ASH:
            case Weather.CONDITION_WINDY:
                return BUCKET_CLOUDY;

            case Weather.CONDITION_THUNDERSTORMS:
            case Weather.CONDITION_SCATTERED_THUNDERSTORMS:
            case Weather.CONDITION_CHANCE_OF_THUNDERSTORMS:
                return BUCKET_THUNDER;

            case Weather.CONDITION_RAIN:
            case Weather.CONDITION_LIGHT_RAIN:
            case Weather.CONDITION_HEAVY_RAIN:
            case Weather.CONDITION_SCATTERED_SHOWERS:
            case Weather.CONDITION_LIGHT_SHOWERS:
            case Weather.CONDITION_SHOWERS:
            case Weather.CONDITION_HEAVY_SHOWERS:
            case Weather.CONDITION_CHANCE_OF_SHOWERS:
            case Weather.CONDITION_DRIZZLE:
            case Weather.CONDITION_UNKNOWN_PRECIPITATION:
            case Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN:
            case Weather.CONDITION_SQUALL:
            case Weather.CONDITION_TROPICAL_STORM:
            case Weather.CONDITION_HURRICANE:
            case Weather.CONDITION_TORNADO:
                return BUCKET_RAIN;

            case Weather.CONDITION_SNOW:
            case Weather.CONDITION_LIGHT_SNOW:
            case Weather.CONDITION_HEAVY_SNOW:
            case Weather.CONDITION_LIGHT_RAIN_SNOW:
            case Weather.CONDITION_HEAVY_RAIN_SNOW:
            case Weather.CONDITION_RAIN_SNOW:
            case Weather.CONDITION_WINTRY_MIX:
            case Weather.CONDITION_CHANCE_OF_SNOW:
            case Weather.CONDITION_CHANCE_OF_RAIN_SNOW:
            case Weather.CONDITION_CLOUDY_CHANCE_OF_SNOW:
            case Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN_SNOW:
            case Weather.CONDITION_FLURRIES:
            case Weather.CONDITION_FREEZING_RAIN:
            case Weather.CONDITION_SLEET:
            case Weather.CONDITION_ICE_SNOW:
            case Weather.CONDITION_HAIL:
            case Weather.CONDITION_ICE:
                return BUCKET_SNOW;

            default:
                return BUCKET_CLEAR;
        }
    }

    // ── Sun/moon arc position, anchored to real sunrise/sunset ──────────
    // Ported from Kadi's celestialFraction: day interpolates linearly from
    // sunrise (0) to sunset (1); night interpolates sunset (0) to the next
    // sunrise (1), reusing today's sunrise/sunset complication values as a
    // stand-in for "yesterday's sunset"/"tomorrow's sunrise" clock time,
    // since they only drift ~1-2 min/day - close enough not to need to
    // track which calendar day they belong to.
    private function celestialFraction(nowSec as Number, sunriseSec as Number, sunsetSec as Number, isDay as Boolean) as Float {
        var frac;
        if (isDay) {
            var denom = sunsetSec - sunriseSec;
            if (denom <= 0) { denom = 43200; }
            frac = (nowSec - sunriseSec).toFloat() / denom;
        } else {
            var nightTotal = (86400 - sunsetSec) + sunriseSec;
            if (nightTotal <= 0) { nightTotal = 43200; }
            var elapsed;
            if (nowSec >= sunsetSec) {
                elapsed = nowSec - sunsetSec;
            } else {
                elapsed = (86400 - sunsetSec) + nowSec;
            }
            frac = elapsed.toFloat() / nightTotal;
        }
        if (frac < 0.0) { frac = 0.0; }
        if (frac > 1.0) { frac = 1.0; }
        return frac;
    }

    // ── Small helpers ─────────────────────────────────────────────────
    private function polarPoint(cx as Numeric, cy as Numeric, radius as Numeric, angleDeg as Numeric) as Array<Float> {
        var rad = Math.toRadians(angleDeg);
        return [cx + radius * Math.cos(rad), cy - radius * Math.sin(rad)];
    }

    // Shared by arcTextSpanDeg/drawArcText/drawArcLetter - all three need the
    // same "how much is this letter shrunk to fit LETTER_TARGET_H" factor,
    // previously computed independently (and identically) in each.
    private function letterScale(bmp) as Float {
        return LETTER_TARGET_H.toFloat() / bmp.getHeight();
    }

    private function drawBitmapCentered(dc as Graphics.Dc, bmp, cx as Numeric, cy as Numeric) as Void {
        dc.drawBitmap((cx - bmp.getWidth() / 2).toNumber(), (cy - bmp.getHeight() / 2).toNumber(), bmp);
    }

    private function formatThousands(n as Number) as String {
        var s = n.toString();
        var out = "";
        var len = s.length();
        var count = 0;
        var i = len - 1;
        while (i >= 0) {
            out = s.substring(i, i + 1) + out;
            count += 1;
            if (count % 3 == 0 && i != 0) {
                out = "," + out;
            }
            i -= 1;
        }
        return out;
    }

    private function formatDistance(meters) as String {
        if (meters == null) {
            return MISSING_VALUE;
        }
        return (meters / 1000.0).format("%.1f");
    }

    private function formatTemperature(celsius) as String {
        if (celsius == null) {
            return MISSING_VALUE + "°";
        }
        return celsius.format("%d") + "°C";
    }

    // ── Drawing layers ───────────────────────────────────────────────────
    // Plain white face fill, drawn first so every other layer paints on
    // top of it - the ring is drawn last (see drawRing) as a stroke, not a
    // fill, so it doesn't erase whatever the scene painted underneath.
    private function drawFaceBase(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(mCenterX, mCenterY, mRadius);
    }

    // Drawn after the scene but before the weather badge (see onUpdate) as an
    // annulus stroke centered on mRingRadius, not a fill - so it paints over
    // any skyline/cloud pixels that reach the outer band instead of the
    // scene bleeding over it, while the badge still draws on top of it.
    private function drawRing(dc as Graphics.Dc) as Void {
        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(mRingPen);
        dc.drawCircle(mCenterX, mCenterY, mRingRadius);

        var starSize = mStarSize;
        // 12, 3, 9 o'clock only - 6 o'clock's star is drawn oversized behind
        // the weather badge instead (see drawWeatherBadge) so its points
        // peek out past the badge's edge.
        for (var i = 0; i < 4; i += 1) {
            if (i == 2) {
                continue;
            }
            var deg = 90 - i * 90;
            var pt = polarPoint(mCenterX, mCenterY, mRingRadius, deg);
            dc.drawScaledBitmap(
                (pt[0] - starSize / 2).toNumber(), (pt[1] - starSize / 2).toNumber(),
                starSize, starSize, mIconStar
            );
        }
    }

    // Each letter's actual on-screen width (at LETTER_TARGET_H) converted to
    // an arc angle (angle = width/radius), plus a gapDeg gap between letters -
    // natural left-to-right character advance, not a stretch-to-fill-the-
    // range layout (which read as too spread out and let the end letters
    // drift into the weather badge/ring stars). gapDeg is a per-call knob
    // (not a fixed constant) so a short word with room to spare (KADISHA)
    // can be spread wider while a long one squeezed between the badge and a
    // ring star (MUKHAMEDJANOVA) can be packed tighter. Unsupported
    // characters (spaces, letters with no extracted glyph) are skipped
    // entirely, including from spacing.
    private function arcTextSpanDeg(text as String, radius as Numeric, gapDeg as Float) as Float {
        var chars = text.toCharArray();
        var totalDeg = 0.0;
        var n = 0;
        for (var i = 0; i < chars.size(); i += 1) {
            var bmp = mLetters.get(chars[i].toString());
            if (bmp == null) {
                continue;
            }
            totalDeg += Math.toDegrees((bmp.getWidth() * letterScale(bmp)) / radius);
            n += 1;
        }
        if (n > 1) {
            totalDeg += (n - 1) * gapDeg;
        }
        return totalDeg;
    }

    // Draws `text` curved along the ring band, starting at startDeg and
    // reading in the direction of increasing angle on the BOTTOM half of the
    // ring (9 -> 6 -> 3 o'clock) or decreasing angle on the TOP half
    // (9 -> 12 -> 3 o'clock) - same polar convention as polarPoint (90=12
    // o'clock, 0=3 o'clock, 180=9 o'clock, 270=6 o'clock). See arcTextSpanDeg
    // for the per-letter spacing (always a positive magnitude regardless of
    // direction). Callers that need to anchor the END of a word at a
    // specific angle (e.g. clearing a ring star) instead of the start should
    // pass `endDeg -/+ arcTextSpanDeg(text, radius, gapDeg)` (minus on the
    // bottom half, plus on the top half).
    //
    // Each letter is rotated so its own "up" points either at the ring's
    // center (bottom half) or away from it (top half) - whichever keeps
    // text right side up and readable in the direction it's flowing. Top-
    // half text reading 9->12->3 has "up" pointing outward for the same
    // reason a clock's 12 numeral is upright with its top away from center;
    // bottom-half text reading 9->6->3 needs the opposite (see the ~2026-07
    // KADISHA/MUKHAMEDJANOVA derivation this generalizes: solving for the
    // rotation that maps local up (0,-1) to the desired world direction at
    // each point, given the text's direction of travel).
    private function drawArcText(dc as Graphics.Dc, text as String, startDeg as Float, radius as Numeric, gapDeg as Float, topHalf as Boolean) as Void {
        var chars = text.toCharArray();
        var dir = topHalf ? -1.0 : 1.0;
        var deg = startDeg;
        for (var i = 0; i < chars.size(); i += 1) {
            var bmp = mLetters.get(chars[i].toString());
            if (bmp == null) {
                continue;
            }
            var charSpanDeg = Math.toDegrees((bmp.getWidth() * letterScale(bmp)) / radius);
            var centerDeg = deg + dir * charSpanDeg / 2.0;
            drawArcLetter(dc, bmp, centerDeg, radius, topHalf);
            deg += dir * (charSpanDeg + gapDeg);
        }
    }

    private function drawArcLetter(dc as Graphics.Dc, bmp, centerDeg as Float, radius as Numeric, topHalf as Boolean) as Void {
        var pt = polarPoint(mCenterX, mCenterY, radius, centerDeg);
        var scale = letterScale(bmp);
        var rotDeg = topHalf ? (90.0 - centerDeg) : -(centerDeg + 90.0);

        var xform = new Graphics.AffineTransform();
        xform.translate(pt[0], pt[1]);
        xform.rotate(Math.toRadians(rotDeg));
        xform.scale(scale, scale);
        xform.translate(-bmp.getWidth() / 2.0, -bmp.getHeight() / 2.0);
        // FILTER_MODE_BILINEAR, not the drawBitmap2 default of POINT (nearest-
        // neighbor) - point sampling this font's dense parallel stripe
        // pattern (see K/A's diagonal strokes) through a combined rotate+
        // downscale produced moire/garbled letters; bilinear fixes it.
        dc.drawBitmap2(0, 0, bmp, {:transform => xform, :filterMode => Graphics.FILTER_MODE_BILINEAR});
    }

    // Rolls continuously around the ring (one full revolution per minute)
    // instead of jumping between 60 fixed tick positions - see mLastSec's
    // field comment for how the sub-second fraction is derived without a
    // true sub-second clock API. Drawn before the weather badge (see
    // onUpdate) so the badge visually covers it during the ~6 o'clock pass
    // instead of the marker poking out over the badge.
    private function drawSecondsMarker(dc as Graphics.Dc, sec as Number, nowTimerMs as Number) as Void {
        if (mLastSec == null || mLastSec != sec) {
            mLastSec = sec;
            mLastSecTimerMs = nowTimerMs;
        }
        var msWithinSecond = nowTimerMs - mLastSecTimerMs;
        if (msWithinSecond < 0 || msWithinSecond > 999) {
            msWithinSecond = 0;
        }
        var secFrac = (sec + msWithinSecond / 1000.0) / 60.0;
        var deg = 90.0 - secFrac * 360.0;

        // Drawn unscaled (not drawScaledBitmap) so its real alpha channel
        // blends correctly - see drawScene's skyline comment for the same
        // drawScaledBitmap alpha issue. icon_seconds.png is pre-scaled at
        // asset-prep time to the exact pixel size this draws at (fr970-only
        // target), so dropping the runtime scale has no visible size effect,
        // it just leaves a solid-color box where the ring shows through
        // behind the glyph.
        // Orbits on mRingRadius (the ring band's own centerline) with a
        // bubble radius kept inside the band's half-width, so the whole
        // bubble stays within the dark navy ring instead of poking past its
        // inner or outer edge. mRingRadius is pushed 2px past the display's
        // true edge radius on purpose (see onLayout) so the ring stroke
        // itself covers the round bezel with no hairline gap - but that
        // means a bubble radius as large as the band's own half-width
        // still pokes ~1px past the true screen edge and gets clipped on
        // a real round display. -4 (not -1) pulls the outer edge back
        // inside the true edge with a couple px of margin.
        var pt = polarPoint(mCenterX, mCenterY, mRingRadius, deg);
        var ptX = pt[0].toNumber();
        var ptY = pt[1].toNumber();
        var bubbleRadius = (mRingPen / 2).toNumber() - 4;
        dc.setColor(COLOR_SKY_DAY, COLOR_SKY_DAY);
        dc.fillCircle(ptX, ptY, bubbleRadius);
        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        dc.drawCircle(ptX, ptY, bubbleRadius);
        drawBitmapCentered(dc, mIconSeconds, ptX, ptY);
    }

    private function drawBattery(dc as Graphics.Dc) as Void {
        var level = System.getSystemStats().battery.toNumber();
        var bodyW = 34;
        var bodyH = 19;
        var nubW = 5;
        var nubH = 9;
        var font = mFontBattery;
        var text = level.toString() + "%";
        var textW = dc.getTextDimensions(text, font)[0];
        var totalW = bodyW + nubW + 6 + textW;
        var left = (mCenterX - totalW / 2).toNumber();
        var top = (mYBattery - bodyH / 2).toNumber();

        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(left, top, bodyW, bodyH, 2);
        // Contact nub protrudes from the body's right edge, not drawn inside it.
        dc.setColor(COLOR_NAVY, COLOR_NAVY);
        dc.fillRectangle(left + bodyW - 1, top + (bodyH - nubH) / 2, nubW, nubH);
        var pad = 2;
        var innerW = bodyW - pad * 2;
        var innerH = bodyH - pad * 2;
        var clampedLevel = level;
        if (clampedLevel < 0) { clampedLevel = 0; }
        if (clampedLevel > 100) { clampedLevel = 100; }
        var fillW = (innerW * clampedLevel / 100).toNumber();
        if (fillW > 0) {
            dc.fillRectangle(left + pad, top + pad, fillW, innerH);
        }

        // Reset background to transparent - the nub fill above left it opaque
        // navy, which would otherwise paint the text's bounding box solid
        // navy instead of just the (also-navy) glyph strokes.
        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left + bodyW + nubW + 6, mYBattery, font, text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function drawDateRow(dc as Graphics.Dc) as Void {
        var font = mFontDate;
        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mYDate, font, mDateStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function renderTime(dc as Graphics.Dc, cx as Numeric, y as Numeric, hour as Number, min as Number) as Void {
        var hd1 = hour / 10;
        var hd2 = hour % 10;
        var md1 = min / 10;
        var md2 = min % 10;

        var scaledH = GLYPH_CANVAS_H * TIME_SCALE;
        var top = (y - scaledH / 2).toNumber();
        var gap = TIME_DIGIT_GAP * TIME_SCALE;
        var colonGap = TIME_COLON_GAP * TIME_SCALE;

        // Colon renders at its own smaller scale (COLON_HEIGHT_FRAC of the
        // digits' height) so it reads as a colon, not a third digit - vertically
        // centered on the same y as the digits rather than sharing their
        // (taller) canvas top.
        var colonScale = TIME_SCALE * COLON_HEIGHT_FRAC;
        var colonScaledH = GLYPH_CANVAS_H * colonScale;
        var colonTop = (y - colonScaledH / 2).toNumber();

        var totalW = (DIGIT_INK_W[hd1] + DIGIT_INK_W[hd2] + DIGIT_INK_W[md1] + DIGIT_INK_W[md2]) * TIME_SCALE
            + gap * 2 + colonGap * 2 + COLON_INK_W * colonScale;
        var drawX = (cx - totalW / 2).toFloat();

        drawTimeGlyph(dc, mDigits[hd1], drawX, top, scaledH, DIGIT_PAD_LEFT[hd1], TIME_SCALE);
        drawX += DIGIT_INK_W[hd1] * TIME_SCALE + gap;
        drawTimeGlyph(dc, mDigits[hd2], drawX, top, scaledH, DIGIT_PAD_LEFT[hd2], TIME_SCALE);
        drawX += DIGIT_INK_W[hd2] * TIME_SCALE + colonGap;

        drawTimeGlyph(dc, mColon, drawX, colonTop, colonScaledH, COLON_PAD_LEFT, colonScale);
        drawX += COLON_INK_W * colonScale + colonGap;

        drawTimeGlyph(dc, mDigits[md1], drawX, top, scaledH, DIGIT_PAD_LEFT[md1], TIME_SCALE);
        drawX += DIGIT_INK_W[md1] * TIME_SCALE + gap;
        drawTimeGlyph(dc, mDigits[md2], drawX, top, scaledH, DIGIT_PAD_LEFT[md2], TIME_SCALE);
    }

    // Draws one glyph scaled by `scale` so its ink-left lands at drawX (the
    // ink-cursor position), matching the unscaled canvas-left/pad-left
    // relationship used to build DIGIT_PAD_LEFT/DIGIT_INK_W in the first
    // place. Takes an explicit scale rather than always using TIME_SCALE so
    // the colon can render at its own smaller COLON_HEIGHT_FRAC scale.
    private function drawTimeGlyph(dc as Graphics.Dc, bmp, drawX as Float, top as Numeric, scaledH as Float, padLeft as Numeric, scale as Float) as Void {
        var scaledW = bmp.getWidth() * scale;
        var left = drawX - padLeft * scale;
        dc.drawScaledBitmap(left.toNumber(), top, scaledW.toNumber(), scaledH.toNumber(), bmp);
    }

    // Cloud positions/sizes for the light-clouds look (BUCKET_PARTLY, matches
    // the original approved mockup exactly - left unchanged). CLOUDY and the
    // precip buckets reuse the same 5 sprites and positions but scaled up by
    // CLOUD_DENSE_SCALE and pulled toward the horizon center so they overlap
    // into a fuller-looking cover, rather than needing dedicated art.
    private function drawClouds(dc as Graphics.Dc, w as Numeric, h as Numeric, isDay as Boolean, bucket as Number) as Void {
        if (bucket == BUCKET_CLEAR) {
            return;
        }
        var clouds = isDay ? mDayClouds : mNightClouds;
        var cx = [w * 0.40, w * 0.74, w * 0.18, w * 0.56, w * 0.85];
        var cy = [mYHorizon + h * 0.09, mYHorizon + h * 0.06, mYHorizon + h * 0.19, mYHorizon + h * 0.20, mYHorizon + h * 0.19];

        if (bucket == BUCKET_PARTLY) {
            for (var i = 0; i < 5; i += 1) {
                drawBitmapCentered(dc, clouds[i], cx[i], cy[i]);
            }
            return;
        }

        // CLOUDY/RAIN/SNOW/THUNDER: same 5 sprites, scaled up and pulled
        // toward the horizon's center so they visually merge into denser
        // cover instead of the airy, well-spaced PARTLY arrangement.
        for (var i = 0; i < 5; i += 1) {
            var bmp = clouds[i];
            var bw = (bmp.getWidth() * CLOUD_DENSE_SCALE).toNumber();
            var bh = (bmp.getHeight() * CLOUD_DENSE_SCALE).toNumber();
            var px = cx[i] + (mCenterX - cx[i]) * 0.15;
            var py = cy[i] + (mYHorizon - cy[i]) * 0.15;
            dc.drawScaledBitmap((px - bw / 2).toNumber(), (py - bh / 2).toNumber(), bw, bh, bmp);
        }
    }

    // Ported from Kadi's drawPrecip (KadiWatchFace.mc) - tiles the 3-frame
    // rain/snow sprite set across the sky band with a continuous fall offset
    // derived from System.getTimer() (wrapped to one tile height) so it
    // reads as falling rather than jumping to a new spot every redraw. Rain
    // drifts along the diagonal baked into the art; snow flutters with a
    // sine sway instead of tracking a fixed wind line.
    private function drawPrecip(dc as Graphics.Dc, w as Numeric, h as Numeric, bucket as Number) as Void {
        var tiles;
        if (bucket == BUCKET_RAIN || bucket == BUCKET_THUNDER) {
            tiles = mRainTiles;
        } else if (bucket == BUCKET_SNOW) {
            tiles = mSnowTiles;
        } else {
            return;
        }

        var tileSize = tiles[0].getWidth();
        var isRain = (bucket == BUCKET_RAIN || bucket == BUCKET_THUNDER);
        var fallMs = isRain ? RAIN_FALL_MS : SNOW_FALL_MS;

        var elapsedMs = System.getTimer();
        var offsetY = elapsedMs % fallMs * tileSize / fallMs;

        var offsetX;
        if (isRain) {
            offsetX = (offsetY * RAIN_DRIFT_RATIO).toNumber();
        } else {
            var swayPhase = (elapsedMs % SNOW_SWAY_PERIOD_MS).toFloat() / SNOW_SWAY_PERIOD_MS;
            offsetX = (Math.sin(swayPhase * 2 * Math.PI) * SNOW_SWAY_PX).toNumber();
        }

        var startY = mYHorizonClipTop;
        var y = startY;
        var row = 0;
        while (y < h) {
            var x = -tileSize / 2;
            var col = 0;
            while (x < w) {
                var tile = tiles[(row + col) % tiles.size()];
                dc.drawBitmap(x + offsetX, y + offsetY, tile);
                x += tileSize;
                col += 1;
            }
            y += tileSize;
            row += 1;
        }
    }

    // Simple procedural bolt (no bitmap asset) - only visible on
    // BUCKET_THUNDER, and only for THUNDER_FLASH_DURATION_MS out of every
    // THUNDER_FLASH_PERIOD_MS, so it reads as an occasional flash rather
    // than a static decoration.
    private function drawThunderFlash(dc as Graphics.Dc, w as Numeric, h as Numeric, bucket as Number) as Void {
        if (bucket != BUCKET_THUNDER) {
            return;
        }
        if (System.getTimer() % THUNDER_FLASH_PERIOD_MS >= THUNDER_FLASH_DURATION_MS) {
            return;
        }

        var bx = mCenterX + w * 0.06;
        var by = mYHorizon + h * 0.13;
        var boltW = w * 0.05;
        var boltH = h * 0.11;

        dc.setColor(0xFFFFAA, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        dc.drawLine(bx, by, bx - boltW, by + boltH * 0.5);
        dc.drawLine(bx - boltW, by + boltH * 0.5, bx + boltW * 0.3, by + boltH * 0.55);
        dc.drawLine(bx + boltW * 0.3, by + boltH * 0.55, bx - boltW * 0.3, by + boltH);
    }

    private function drawScene(dc as Graphics.Dc, isDay as Boolean, bucket as Number, celestialFrac as Float) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var skyColor = isDay ? COLOR_SKY_DAY : COLOR_SKY_NIGHT;

        // Curved horizon: fill sky across the whole clipped band, then carve
        // the white "smile" back in on top using the big circle computed in
        // onLayout - its bottom arc is deepest (most white) at mCenterX,
        // exactly where the stats row content sits, and rises toward the
        // ring at the sides where there's nothing to clip.
        dc.setClip(0, mYHorizonClipTop, w, h - mYHorizonClipTop);
        dc.setColor(skyColor, skyColor);
        dc.fillCircle(mCenterX, mCenterY, mRadius);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(mCenterX, mHorizonCircleCy.toNumber(), mHorizonCircleR.toNumber());

        if (!isDay) {
            dc.drawBitmap(0, 0, mStars);
        }

        // Parabolic arc: low (near the horizon) at frac=0/1 (rise/set),
        // peaking at frac=0.5 - celestialFrac is 0 exactly at sunrise/sunset
        // (see celestialFraction), so the rise/set points line up with the
        // real local sunrise/sunset times the sunrise/sunset complications
        // report, not a fixed clock guess.
        var celestial = isDay ? mSun : mMoonPhases[mMoonPhaseIndex];
        var celLowY = mYHorizon + h * CELESTIAL_ARC_LOW_FRAC;
        var celArcH = h * CELESTIAL_ARC_HEIGHT_FRAC;
        var celX = w * CELESTIAL_ARC_X0 + celestialFrac * w * (CELESTIAL_ARC_X1 - CELESTIAL_ARC_X0);
        var celY = celLowY - 4.0 * celArcH * celestialFrac * (1.0 - celestialFrac);
        drawBitmapCentered(dc, celestial, celX, celY);

        drawClouds(dc, w, h, isDay, bucket);
        drawPrecip(dc, w, h, bucket);

        // Re-carve the white "smile" on top of the precip field: unlike
        // Kadi's flat rectangular clip, chistana's horizon is curved, so a
        // precip tile tiled across the full clip rectangle can paint sky
        // pixels into what should be white dial near the rectangle's upper
        // corners. Redrawing this matte is a cheap no-op everywhere else.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(mCenterX, mHorizonCircleCy.toNumber(), mHorizonCircleR.toNumber());

        // Drawn unscaled (not drawScaledBitmap) so its real alpha channel
        // blends correctly - drawScaledBitmap doesn't alpha-blend reliably
        // on this simulator/device (see extract_skyline.py's TARGET_W
        // comment), which showed up as a solid black box here. The PNG is
        // pre-scaled at extraction time to the exact pixel width this
        // formula would have scaled it to anyway (fr970-only target), so
        // dropping the runtime scale has no visible size effect.
        var skyline = isDay ? mDaySkyline : mNightSkyline;
        var skylineW = skyline.getWidth();
        var skylineH = skyline.getHeight();
        var skylineBottom = (h * 0.90).toNumber();
        dc.drawBitmap((mCenterX - skylineW / 2).toNumber(), skylineBottom - skylineH, skyline);

        drawThunderFlash(dc, w, h, bucket);

        dc.clearClip();
    }

    private function drawStatsRow(dc as Graphics.Dc) as Void {
        var font = mFontStatValue;
        var labelFont = mFontStatLabel;

        var actInfo = Activity.getActivityInfo();
        var hrVal = (actInfo != null && actInfo.currentHeartRate != null) ? actInfo.currentHeartRate.toString() : MISSING_VALUE;
        var monInfo = ActivityMonitor.getInfo();
        var stepsVal = (monInfo != null && monInfo.steps != null) ? formatThousands(monInfo.steps) : MISSING_VALUE;
        var distVal = formatDistance(mWeeklyDistanceM);

        // No more icons above the value - value+label pair is vertically
        // centered on mYStats now that the glyph row is gone.
        var valueY = mYStats - 3;
        var labelY = mYStats + 23;

        // Steps (middle column) and the two side dividers still sit a bit
        // lower than hr/km, closer to the horizon curve - the curve has the
        // most vertical clearance near center, so only this column needs to
        // move.
        var midOffset = 10;
        var midValueY = valueY + midOffset;
        var midLabelY = labelY + midOffset;

        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mStatColX[0], valueY, font, hrVal, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mStatColX[1], midValueY, font, stepsVal, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mStatColX[2], valueY, font, distVal, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mStatColX[0], labelY, labelFont, "bpm", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mStatColX[1], midLabelY, labelFont, "steps", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mStatColX[2], labelY, labelFont, "km", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var dividerTop = valueY - 18 + midOffset;
        var dividerBottom = labelY + 12 + midOffset;
        dc.setPenWidth(1);
        dc.setColor(0xCCCCCC, Graphics.COLOR_TRANSPARENT);
        var midLeft = ((mStatColX[0] + mStatColX[1]) / 2).toNumber();
        var midRight = ((mStatColX[1] + mStatColX[2]) / 2).toNumber();
        dc.drawLine(midLeft, dividerTop, midLeft, dividerBottom);
        dc.drawLine(midRight, dividerTop, midRight, dividerBottom);
    }

    private function drawWeatherBadge(dc as Graphics.Dc, bucket as Number, tempStr as String) as Void {
        // Oversized 6 o'clock star, centered behind the badge - icon_star's
        // longest points reach almost exactly to its canvas edge (measured
        // via extract tooling), so only a modest size past the badge's own
        // diameter is needed for the points to clear its edge; this is not
        // the same ratio as the ring-position stars, which are sized to sit
        // fully inside the ring band instead of poking past a circle.
        var badgeStarSize = (mBadgeRadius * 2.5).toNumber();
        dc.drawScaledBitmap(
            (mCenterX - badgeStarSize / 2).toNumber(), (mYBadgeCenter - badgeStarSize / 2).toNumber(),
            badgeStarSize, badgeStarSize, mIconStar
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(mCenterX, mYBadgeCenter, mBadgeRadius);
        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(mCenterX, mYBadgeCenter, mBadgeRadius);

        var font = mFontBadge;
        var icon = mWeatherIcons[bucket];
        var iconScale = 0.82;
        var iconW = (icon.getWidth() * iconScale).toNumber();
        var iconH = (icon.getHeight() * iconScale).toNumber();
        var iconCy = mYBadgeCenter - 14;
        dc.drawScaledBitmap((mCenterX - iconW / 2).toNumber(), (iconCy - iconH / 2).toNumber(), iconW, iconH, icon);
        dc.setColor(COLOR_NAVY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mYBadgeCenter + 9, font, tempStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Everything except the seconds marker and weather badge - rendered into
    // mStaticBuffer at most once/sec (see STATIC_REFRESH_INTERVAL_MS), not on
    // every fast onUpdate tick. See mStaticBuffer's field comment for why.
    private function drawStaticScene(dc as Graphics.Dc, isDay as Boolean, bucket as Number, celestialFrac as Float, hour as Number, min as Number) as Void {
        drawFaceBase(dc);
        drawScene(dc, isDay, bucket, celestialFrac);
        drawBattery(dc);
        drawDateRow(dc);
        renderTime(dc, mCenterX, mYTime, hour, min);
        drawStatsRow(dc);
        drawRing(dc);
        // KADISHA starts 9 degrees clockwise of the 9 o'clock star and, with
        // only 7 letters, has plenty of room left in its 9-6 quadrant before
        // the badge - a wide gap spreads it across most of that quadrant
        // instead of leaving it bunched up near the star.
        var kadishaGapDeg = 6.5;
        drawArcText(dc, "KADISHA", 189.0, mRingRadius, kadishaGapDeg, false);

        // MUKHAMEDJANOVA is anchored by its END, 9 degrees counter-clockwise
        // of the 3 o'clock star, with its start computed backwards from that.
        // It's 14 letters packed into the same size quadrant as KADISHA's 7,
        // squeezed between that star and the badge - a tight gap (not
        // KADISHA's wide one) is what gives its start real clearance off the
        // badge instead of just barely grazing it.
        var mukhText = "MUKHAMEDJANOVA";
        var mukhGapDeg = 0.9;
        var mukhEnd = 354.0;
        var mukhStart = mukhEnd - arcTextSpanDeg(mukhText, mRingRadius, mukhGapDeg);
        drawArcText(dc, mukhText, mukhStart, mRingRadius, mukhGapDeg, false);

        // Top-half words read 9->12->3 (decreasing angle, topHalf=true - see
        // drawArcText). ASTANA starts 9 degrees off the 9 o'clock star and
        // flows toward 12; CHICAGO starts 9 degrees off the 12 o'clock star
        // and flows toward 3 - each word's gap is tuned so it fills most of
        // its quadrant (same "spread out" look as KADISHA) while still
        // clearing the star at the far end.
        drawArcText(dc, "ASTANA", 171.0, mRingRadius, 8.5, true);
        drawArcText(dc, "CHICAGO", 81.0, mRingRadius, 6.8, true);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var clockTime = System.getClockTime();
        var nowMs = System.getTimer();

        // System.getTimer() wraps back to 0 after ~24.8 days - the
        // nowMs < mLastStaticRefreshMs branch catches that and forces a
        // refresh instead of stalling for another ~24.8 days.
        var needsRefresh = (mStaticBuffer == null) || (mLastStaticRefreshMs == null) ||
            (nowMs < mLastStaticRefreshMs) || (nowMs - mLastStaticRefreshMs >= STATIC_REFRESH_INTERVAL_MS);

        if (needsRefresh) {
            var nowSec = clockTime.hour * 3600 + clockTime.min * 60 + clockTime.sec;
            var sunriseSec = mSunriseSec != null ? mSunriseSec : 6 * 3600;
            var sunsetSec = mSunsetSec != null ? mSunsetSec : 18 * 3600;
            if (sunriseSec >= sunsetSec) {
                sunriseSec = 6 * 3600;
                sunsetSec = 18 * 3600;
            }
            var isDay = (nowSec >= sunriseSec) && (nowSec <= sunsetSec);
            var celestialFrac = celestialFraction(nowSec, sunriseSec, sunsetSec, isDay);

            updateMoonPhase();

            var weather = Weather.getCurrentConditions();
            mCachedBucket = mapCondition(weather != null ? weather.condition : null);
            mCachedTempStr = weather != null ? formatTemperature(weather.temperature) : MISSING_TEMP_STR;

            var targetDc = mStaticBuffer != null ? mStaticBuffer.getDc() : dc;
            drawStaticScene(targetDc, isDay, mCachedBucket, celestialFrac, clockTime.hour, clockTime.min);
            mLastStaticRefreshMs = nowMs;
        }

        if (mStaticBuffer != null) {
            dc.drawBitmap(0, 0, mStaticBuffer);
        }
        // Marker before badge - see mStaticBuffer's field comment: the badge
        // must stay on top so it visually covers the marker during its
        // ~6 o'clock pass. Reuses nowMs (already fetched above for the
        // static-buffer staleness check) instead of calling
        // System.getTimer() again - same instant, one fewer system call on
        // every SECONDS_TIMER_INTERVAL_MS tick.
        drawSecondsMarker(dc, clockTime.sec, nowMs);
        drawWeatherBadge(dc, mCachedBucket, mCachedTempStr);
    }
}
