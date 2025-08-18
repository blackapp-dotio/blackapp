// functions/externalFeeds.js
const functions = require("firebase-functions/v1");
const fetch = (...args) => import("node-fetch").then(({ default: f }) => f(...args));

module.exports = (fn /* regioned functions instance */, _admin) => {
  // ---- Config (Functions config or env) ----
  const TM_KEY =
    (functions.config().tm && functions.config().tm.key) ||
    process.env.TM_API_KEY ||
    "";

  const EB_TOKEN =
    (functions.config().eventbrite && functions.config().eventbrite.token) ||
    process.env.EVENTBRITE_TOKEN ||
    "";

  // ---- CORS helper (simple permissive for GET) ----
  const allowCors = (req, res) => {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    if (req.method === "OPTIONS") {
      res.status(204).send("");
      return false;
    }
    return true;
  };

  // ---- Date helpers ----
  const strictRFC3339 = (d) => {
    // Ensure "YYYY-MM-DDTHH:mm:ssZ"
    const iso = new Date(d).toISOString(); // e.g., 2025-08-16T00:00:00.000Z
    return iso.substring(0, 19) + "Z";     // strip milliseconds
  };

  // Defaults: now...+14 days
  const defaultWindow = () => {
    const now = new Date();
    const end = new Date(now.getTime() + 14 * 24 * 60 * 60 * 1000);
    return { start: now, end };
  };

  // ---- Normalizers (map upstream → shared ExternalEvent shape) ----
  const mapTicketmasterEvents = (json) => {
    const list = (json && json._embedded && json._embedded.events) || [];
    return list.map((e) => {
      const venue = (e._embedded && e._embedded.venues && e._embedded.venues[0]) || {};
      const address = [
        venue.address && (venue.address.line1 || venue.address.line2 || venue.address.line3),
        venue.city && venue.city.name,
        venue.state && venue.state.stateCode,
      ]
        .filter(Boolean)
        .join(", ");

      const dt =
        (e.dates && e.dates.start && (e.dates.start.dateTime || e.dates.start.localDate)) || null;
      const date = dt
        ? new Date(e.dates.start.dateTime || `${e.dates.start.localDate}T00:00:00Z`)
        : new Date();

      const price =
        e.priceRanges && e.priceRanges.length
          ? e.priceRanges[0].min
          : undefined;

      // Pick a wide hero image if present
      let hero = undefined;
      if (Array.isArray(e.images)) {
        const wide = e.images.find((im) => (im.ratio || "").includes("16_9")) || e.images[0];
        hero = wide && wide.url;
      }

      return {
        id: e.id,
        title: e.name || "Event",
        venueName: venue.name || "",
        address,
        date: date.getTime() / 1000, // seconds since epoch
        price: typeof price === "number" ? price : undefined,
        externalURL: e.url || undefined,
        source: "ticketmaster",
        heroImage: hero,
      };
    });
  };

  const mapEventbriteEvents = (json) => {
    const list = (json && Array.isArray(json.events) && json.events) || [];
    return list.map((e) => {
      const v = e.venue || {};
      const address =
        (v.address && (v.address.localized_address_display || v.address.address_1)) ||
        [v.city, v.region, v.country].filter(Boolean).join(", ") ||
        "";

      const dt = (e.start && (e.start.utc || e.start.local)) || null;
      const date = dt ? new Date(e.start.utc || e.start.local) : new Date();

      const hero = e.logo && e.logo.url ? e.logo.url : undefined;

      // Eventbrite price requires extra calls; we keep it undefined unless free
      const price = e.is_free ? 0 : undefined;

      return {
        id: e.id,
        title: e.name && e.name.text ? e.name.text : "Event",
        venueName: v.name || "",
        address,
        date: date.getTime() / 1000,
        price,
        externalURL: e.url || undefined,
        source: "eventbrite",
        heroImage: hero,
      };
    });
  };

  // ============================
  //   Ticketmaster proxy (GET)
  // ============================
  const feedTicketmaster = fn.https.onRequest(async (req, res) => {
    if (!allowCors(req, res)) return;
    if (req.method !== "GET") return res.status(405).json({ error: "Method not allowed" });

    try {
      const city = (req.query.city || "").toString().trim();
      const { start: defStart, end: defEnd } = defaultWindow();

      // parse incoming or default
      const start = req.query.start ? new Date(req.query.start) : defStart;
      const end = req.query.end ? new Date(req.query.end) : defEnd;

      const u = new URL("https://app.ticketmaster.com/discovery/v2/events.json");
      const sp = u.searchParams;
      sp.set("apikey", TM_KEY);
      sp.set("size", "100");
      sp.set("sort", "date,asc");
      // While testing, keep broad. Uncomment to focus on music:
      // sp.set("classificationName", "Music");
      sp.set("startDateTime", strictRFC3339(start));
      sp.set("endDateTime", strictRFC3339(end));
      sp.set("countryCode", "US");
      if (city) sp.set("city", city);

      const resp = await fetch(u.href);
      const json = await resp.json();

      if (!resp.ok || (json && json.errors)) {
        console.warn("⚠️ Ticketmaster upstream error", resp.status, JSON.stringify(json));
        // Return an empty array so the client/UI doesn't blow up
        return res.status(200).json([]);
      }

      const events = mapTicketmasterEvents(json);
      return res.status(200).json(events);
    } catch (err) {
      console.error("🔥 feedTicketmaster error:", err);
      return res.status(200).json([]); // keep contract (array) even on errors
    }
  });

  // ============================
  //   Eventbrite proxy (GET)
  // ============================
  const feedEventbrite = fn.https.onRequest(async (req, res) => {
    if (!allowCors(req, res)) return;
    if (req.method !== "GET") return res.status(405).json({ error: "Method not allowed" });

    try {
      const city = (req.query.city || "").toString().trim();
      const { start: defStart, end: defEnd } = defaultWindow();

      const start = req.query.start ? new Date(req.query.start) : defStart;
      const end = req.query.end ? new Date(req.query.end) : defEnd;

      const u = new URL("https://www.eventbriteapi.com/v3/events/search/");
      const sp = u.searchParams;

      if (city) {
        sp.set("location.address", city);
        sp.set("location.within", "50mi"); // 👈 important to avoid empty results when only city is supplied
      }

      sp.set("start_date.range_start", strictRFC3339(start));
      sp.set("start_date.range_end", strictRFC3339(end));
      sp.set("expand", "venue");
      sp.set("page_size", "100");
      sp.set("sort_by", "date");

      const resp = await fetch(u.href, {
        headers: {
          Authorization: `Bearer ${EB_TOKEN}`,
          "Content-Type": "application/json",
        },
      });
      const json = await resp.json();

      if (!resp.ok || (json && json.error)) {
        console.warn("⚠️ Eventbrite upstream error", resp.status, JSON.stringify(json));
        return res.status(200).json([]);
      }

      const events = mapEventbriteEvents(json);
      return res.status(200).json(events);
    } catch (err) {
      console.error("🔥 feedEventbrite error:", err);
      return res.status(200).json([]); // keep contract (array)
    }
  });

  return {
    feedTicketmaster,
    feedEventbrite,
  };
};
