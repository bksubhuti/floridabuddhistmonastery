# floridabuddhistmonastery
website for tayzawbatha vihara inc

## Live alms map

- Public map: `/alms-live/`
- Sender page for the phone: `/alms-live/send/` (not linked anywhere, and only the signed-in sender account can write)

### One-time setup (Firebase, free Spark plan)

1. Go to https://console.firebase.google.com and create a project (Google Analytics is not needed).
2. **Build → Realtime Database → Create database**. Pick the US location and start in **locked mode**.
3. **Build → Authentication → Get started → Email/Password → Enable**.
   Then **Users → Add user** with an email and password for the phone. Copy that user's **User UID**.
4. **Realtime Database → Rules**: paste the rules below, replace `PASTE_UID_HERE` with the UID, and click **Publish**:

   ```json
   {
     "rules": {
       ".read": false,
       ".write": false,
       "alms": {
         ".read": true,
         ".write": "auth != null && auth.uid === 'PASTE_UID_HERE'",
         ".validate": "newData.hasChildren(['active', 't'])",
         "active": { ".validate": "newData.isBoolean()" },
         "hidden": { ".validate": "newData.isBoolean()" },
         "lat":    { ".validate": "newData.isNumber()" },
         "lng":    { ".validate": "newData.isNumber()" },
         "acc":    { ".validate": "newData.isNumber()" },
         "monks":  { ".validate": "newData.isNumber() && newData.val() >= 1 && newData.val() <= 20" },
         "guests": { "$i": { ".validate": "newData.isString() && newData.val().length < 40" } },
         "t":      { ".validate": "newData.val() === now" },
         "$other": { ".validate": false }
       },
       "alms_guests": {
         ".read": true,
         ".write": "auth != null && auth.uid === 'PASTE_UID_HERE'",
         "$id": {
           "img":    { ".validate": "newData.isString() && newData.val().length < 400000 && newData.val().beginsWith('data:image/png;base64,')" },
           "$other": { ".validate": false }
         }
       },
       "alms_trail": {
         ".read": true,
         ".write": "auth != null && auth.uid === 'PASTE_UID_HERE'",
         "$id": {
           ".validate": "newData.hasChildren(['lat', 'lng', 't'])",
           "lat":    { ".validate": "newData.isNumber()" },
           "lng":    { ".validate": "newData.isNumber()" },
           "t":      { ".validate": "newData.val() === now" },
           "$other": { ".validate": false }
         }
       }
     }
   }
   ```

5. **Project settings → General → Add app → Web (</>)**, register it, then copy the `apiKey`.
   Copy the database URL from the Realtime Database page (for example `https://xxx-default-rtdb.firebaseio.com`).
6. Put both in `_config.yml` under `alms_live:` and push.

### Using it (Android)

1. Open `https://floridabuddhistmonastery.org/alms-live/send/` in Chrome and sign in once.
   Tip: Chrome menu → **Add to Home screen**.
2. At the monastery, tap **Set private zone at my current spot** once. Near the monastery the map then shows only "starting", with no location.
3. Before the alms round, tap **Start sharing** and allow location access. Keep the page open with the screen on.
4. Afterwards, tap **Stop sharing**. If you forget, the map treats the round as ended after 45 minutes without updates.
