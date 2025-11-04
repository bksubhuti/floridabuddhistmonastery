const ICS_URL = "https://calendar.google.com/calendar/ical/a9990f54cc62171dfef7a892c552c8964dc1a18735784e6d8c36803ce3cffb9b%40group.calendar.google.com/public/basic.ics";

const text = await fetch(ICS_URL).then(r => {
    if (!r.ok) throw new Error("Failed to fetch ICS: " + r.status);
    return r.text();
});

// Split into VEVENT blocks
const blocks = text.split("BEGIN:VEVENT").slice(1);

const events = [];
for (const ch of blocks) {
    const endIdx = ch.indexOf("END:VEVENT");
    const body = endIdx >= 0 ? ch.slice(0, endIdx) : ch;

    let allDay = false;
    let startRaw = null;

    const mAll = body.match(/DTSTART;VALUE=DATE:(\d{8})/);
    if (mAll) {
        allDay = true;
        startRaw = mAll[1];
    } else {
        const mAny = body.match(/DTSTART(?:;[^:]+)?:([0-9T]+Z?)/);
        if (mAny) startRaw = mAny[1];
    }

    const mSum = body.match(/SUMMARY:(.+)/);

    if (startRaw && mSum) {
        events.push({
            summary: mSum[1].trim(),
            startRaw,
            allDay
        });
    }
}

import fs from 'fs/promises';
await fs.mkdir('assets', { recursive: true });
await fs.writeFile('assets/events.json', JSON.stringify({ generatedAt: new Date().toISOString(), events }, null, 2));
console.log("Wrote assets/events.json with", events.length, "events");
