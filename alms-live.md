---
title: "Live Alms Round"
permalink: /alms-live/
layout: single
---

The alms round (piṇḍapāta) is usually **7:30 – 8:45 AM**. While the bhikkhus are walking, their current location appears on the map below. It updates by itself, so you can keep this page open.

<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<style>.monk-marker{filter:drop-shadow(0 0 1px #fff) drop-shadow(0 0 1px #fff) drop-shadow(0 3px 3px rgba(0,0,0,.45));}
.monk-marker img{pointer-events:none}
.alms-count{position:absolute;right:-6px;top:-6px;background:#7a1f1f;color:#fff;font:700 11px/1 system-ui,sans-serif;padding:3px 5px;border-radius:9px}
.alms-stamp{box-sizing:border-box;text-align:center;background:rgba(255,255,255,.9);color:#7a1f1f;font:600 11px/17px system-ui,sans-serif;padding:0 3px;border-radius:4px;border:1px solid #e88aac;white-space:nowrap;box-shadow:0 1px 2px rgba(0,0,0,.25);}</style>

<div id="alms-status" class="notice--info">Loading…</div>
<div id="alms-map" style="height:420px;border-radius:8px;margin:1em 0;"></div>

You can find the monks but please do not follow the monks. The location is shown only while the alms round is in progress. It is hidden near the monastery, which is a private residence.

<script>
  window.ALMS_LIVE = {
    databaseUrl: {{ site.alms_live.database_url | jsonify }}
  };
</script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<script src="/assets/js/alms-live.js"></script>
