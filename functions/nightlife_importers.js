// functions/nightlife_importers.js
module.exports = (fn, admin) => {
  const db = admin.database();

  // ENV VARS you must set in Firebase config (don’t hardcode keys):
  // firebase functions:config:set ticketmaster.key="..." seatgeek.client_id="..." eventbrite.token="..."
  const TM_KEY = process.env.TICKETMASTER_KEY || (require('firebase-functions').config().ticketmaster?.key);
  const SG_ID  = process.env.SEATGEEK_CLIENT_ID || (require('firebase-functions').config().seatgeek?.client_id);
  const EB_TOK = process.env.EVENTBRITE_TOKEN || (require('firebase-functions').config().eventbrite?.token);

  const fetch = (...args) => import('node-fetch').then(({ default: fetch }) => fetch(...args));

  // 🔁 Run nightly
  const importExternalNightlife = fn.pubsub.schedule('every 24 hours').onRun(async () => {
    const cities = ['Miami,US', 'New York,US', 'Los Angeles,US']; // TODO: make configurable in RTDB

    for (const city of cities) {
      await Promise.all([
        importTicketmaster(city),
        importSeatGeek(city),
        importEventbrite(city)
      ]);
    }
    return null;
  });

  async function importTicketmaster(city) {
    if (!TM_KEY) return;
    try {
      const url = `https://app.ticketmaster.com/discovery/v2/events.json?classificationName=Music&city=${encodeURIComponent(city)}&size=50&apikey=${TM_KEY}`;
      const res = await fetch(url);
      const json = await res.json();
      const events = json._embedded?.events || [];
      for (const ev of events) {
        const venueObj = ev._embedded?.venues?.[0];
        if (!venueObj) continue;

        const venueId = `tm_${venueObj.id}`;
        await upsertVenueFromTM(venueId, venueObj);

        const nightId = `tm_${ev.id}`;
        await upsertNightFromTM(nightId, venueId, ev);

        // ticketInventory: create an external SKU (single line)
        const skuRef = db.ref(`ticketInventory/${nightId}/tm`);
        await skuRef.update({
          name: ev.name || 'Admission',
          price: parseFloat(ev.priceRanges?.[0]?.min || 0),
          qtyAvailable: null,
          externalURL: ev.url || null,
          source: 'ticketmaster'
        });
      }
    } catch (e) {
      console.error('TM import error', e);
    }
  }

  async function upsertVenueFromTM(venueId, v) {
    const ref = db.ref(`venues/${venueId}`);
    const payload = {
      name: v.name || 'Venue',
      address: [v.address?.line1, v.city?.name, v.state?.name, v.postalCode].filter(Boolean).join(', '),
      geo: v.location ? { lat: parseFloat(v.location.latitude), lng: parseFloat(v.location.longitude) } : null,
      photos: [],
      genres: ['Music'],
      dressCode: null,
      hours: null,
      externalSource: 'ticketmaster'
    };
    await ref.update(payload);
  }

  async function upsertNightFromTM(nightId, venueId, ev) {
    const ref = db.ref(`nights/${nightId}`);
    const dateStr = ev.dates?.start?.dateTime || ev.dates?.start?.localDate;
    const ts = dateStr ? Date.parse(dateStr) / 1000 : Math.floor(Date.now() / 1000);
    const payload = {
      venueId,
      date: ts,
      title: ev.name || 'Night',
      description: ev.info || ev.pleaseNote || '',
      imagePath: ev.images?.[0]?.url || null,
      promoterIds: {},
      status: 'published',
      externalSource: 'ticketmaster',
      sourceId: ev.id
    };
    await ref.update(payload);
  }

  async function importSeatGeek(city) {
    if (!SG_ID) return;
    try {
      const url = `https://api.seatgeek.com/2/events?taxonomies.name=concert&venue.city=${encodeURIComponent(city.split(',')[0])}&client_id=${SG_ID}&per_page=50`;
      const res = await fetch(url);
      const json = await res.json();
      const events = json.events || [];
      for (const ev of events) {
        const v = ev.venue;
        if (!v) continue;
        const venueId = `sg_${v.id}`;
        await db.ref(`venues/${venueId}`).update({
          name: v.name || 'Venue',
          address: [v.address, v.extended_address].filter(Boolean).join(', '),
          geo: (v.location) ? { lat: v.location.lat, lng: v.location.lon } : null,
          photos: [],
          genres: ['Music'],
          dressCode: null,
          hours: null,
          externalSource: 'seatgeek'
        });

        const nightId = `sg_${ev.id}`;
        await db.ref(`nights/${nightId}`).update({
          venueId,
          date: Math.floor(new Date(ev.datetime_local || ev.datetime_utc).getTime() / 1000),
          title: ev.title || 'Night',
          description: ev.description || '',
          imagePath: ev.performers?.[0]?.image || null,
          promoterIds: {},
          status: 'published',
          externalSource: 'seatgeek',
          sourceId: String(ev.id)
        });

        await db.ref(`ticketInventory/${nightId}/sg`).update({
          name: ev.type?.toUpperCase() || "Admission",
          price: parseFloat(ev.stats?.lowest_price || 0),
          qtyAvailable: null,
          externalURL: ev.url || null,
          source: 'seatgeek'
        });
      }
    } catch (e) {
      console.error('SeatGeek import error', e);
    }
  }

  async function importEventbrite(city) {
    if (!EB_TOK) return;
    try {
      const url = `https://www.eventbriteapi.com/v3/events/search/?q=music&location.address=${encodeURIComponent(city)}&expand=venue`;
      const res = await fetch(url, { headers: { Authorization: `Bearer ${EB_TOK}` } });
      const json = await res.json();
      const events = json.events || [];
      for (const ev of events) {
        const v = ev.venue;
        if (!v) continue;
        const venueId = `eb_${v.id}`;
        await db.ref(`venues/${venueId}`).update({
          name: v.name || 'Venue',
          address: [v.address?.address_1, v.address?.city, v.address?.region].filter(Boolean).join(', '),
          geo: (v.latitude && v.longitude) ? { lat: parseFloat(v.latitude), lng: parseFloat(v.longitude) } : null,
          photos: [],
          genres: ['Music'],
          dressCode: null,
          hours: null,
          externalSource: 'eventbrite'
        });

        const nightId = `eb_${ev.id}`;
        const ts = ev.start?.utc ? Math.floor(Date.parse(ev.start.utc) / 1000) : Math.floor(Date.now()/1000);
        await db.ref(`nights/${nightId}`).update({
          venueId,
          date: ts,
          title: ev.name?.text || 'Night',
          description: ev.description?.text || '',
          imagePath: ev.logo?.url || null,
          promoterIds: {},
          status: 'published',
          externalSource: 'eventbrite',
          sourceId: ev.id
        });

        await db.ref(`ticketInventory/${nightId}/eb`).update({
          name: "Admission",
          price: 0, // EB requires per-ticket call for exact price; keep 0 for browsing
          qtyAvailable: null,
          externalURL: ev.url || null,
          source: 'eventbrite'
        });
      }
    } catch (e) {
      console.error('Eventbrite import error', e);
    }
  }

  return { importExternalNightlife };
};

