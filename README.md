# MDPL Meter Readings — Module Map

A reference for how the pieces fit together. Three files make up the whole system.

---

## 1. `schema.sql` — Database (Supabase / Postgres)

| Module | What it does |
|---|---|
| **`operators` table** | One row per person. `id` = matching Supabase Auth user UID. `code` builds their login email (`<code>@mdpl.local`). `role` is `operator` or `control_room` — this is the only thing that gates dashboard access, nothing else. |
| **`meters` table** | Master list of physical meters: code, name, location, `meter_group` (used for dashboard filtering), unit, type, active flag. |
| **`meter_readings` table** | One row per submitted reading. Stores `reading_value`, auto-filled `previous_reading`, a generated `consumption` column, who recorded it, shift, date, and optional `notes` (used to flag a confirmed low/reset reading). |
| **`latest_meter_readings` view** | Returns just the most recent reading per meter — this is what the app queries to show "previous reading" on the entry screen. |
| **`set_previous_reading()` trigger** | Fires before every insert; looks up the last reading for that meter and stamps it into `previous_reading` automatically, so the frontend never has to compute it. |
| **`is_control_room()` function** | One-line helper used inside RLS policies to check "is the logged-in user active and role = control_room". |
| **RLS policies** | `operators`: names are public (needed for the login picker) but only Control Room can edit them. `meters`: any logged-in user can read; only Control Room can add/edit. `meter_readings`: any logged-in user can read (dashboard + previous-reading lookups); operators can only insert rows attributed to themselves (`auth.uid() = recorded_by`); only Control Room can edit/delete (used for fixing bad readings after the fact). |
| **Seed data** | 5 sample meters — replace with your real list via Table Editor. |

`migration_control_room.sql` is a one-time patch for the project you already created (renamed `supervisor` → `control_room` in place). Not needed for a fresh project — the current `schema.sql` already has it built in.

---

## 2. `index.html` — Frontend (single file, no build step)

Everything lives in one file: HTML structure, Tailwind CDN for styling, and one `<script>` block for logic. Rough sections top to bottom:

| Section | What it does |
|---|---|
| **Config** | `SUPABASE_URL` / `SUPABASE_ANON_KEY` — the only two values you edit per deployment. |
| **State object** | Holds current operator, meter list, selected meter, previous reading, PIN-in-progress, dashboard filter state. Nothing persisted beyond the page session except the Supabase Auth session itself (handled by the SDK). |
| **Login flow** | `initLogin()` → checks for an existing session first (so a phone stays logged in between visits) → `loadOperatorPicker()` shows tappable name buttons → `openPinPad()` / `pinDigit()` build a 4-digit PIN → `attemptLogin()` converts the operator's `code` into `<code>@mdpl.local` and calls `signInWithPassword`. |
| **Operator Entry view** | Shift dropdown → searchable meter picker (`selectMeter()` also fetches the previous reading from the view) → reading input → live consumption calculation (`updateConsumption()`) with the amber "confirm" state for a reading lower than previous → submit handler that inserts the row and resets the form for the next meter. |
| **Control Room Dashboard view** | Only shown if `role === 'control_room'`. Filters (date/shift/group/search) → `refreshDashboard()` queries readings joined with meter + operator info → `renderChecklist()` shows read/pending per meter → `renderLiveTable()` shows the raw feed → `subscribeRealtime()` opens a Supabase Realtime channel so new readings appear without refreshing → `exportCsv()` builds a CSV client-side from whatever's currently filtered. |
| **Toast helper** | Small reusable function for the save-confirmation / error popups. |

---

## 3. `SETUP.md` — One-time provisioning steps

Covers: creating the Supabase project → running `schema.sql` → creating an Auth user + matching `operators` row per person (this is the manual step, one-time per operator) → adding real meters → copying credentials into `index.html` → local testing → GitHub Pages deployment → day-to-day admin notes (deactivating an operator, fixing a bad reading, adding a meter).

---

## How a reading actually flows through the system

```
Operator taps name → PIN → Supabase Auth session created
        ↓
Picks shift + meter → app queries latest_meter_readings for "previous"
        ↓
Types new reading → consumption computed client-side, live
        ↓
Submit → INSERT into meter_readings
        ↓
   trigger stamps previous_reading automatically
   RLS checks recorded_by = auth.uid()
        ↓
Realtime broadcasts the change → Control Room dashboard updates instantly
```

## Things to know for future changes

- **Role gate is one string comparison** (`role === 'control_room'`), checked in both the frontend (`showMainApp()`) and the database (`is_control_room()`). Change it in both places if it ever needs a third role.
- **Consumption is a generated column** — you never write to it directly; it's always `reading_value - previous_reading`.
- **The trigger only fires on INSERT**, not UPDATE — so if Control Room manually edits a `reading_value` later, `previous_reading` for that row stays as originally recorded. Consumption still recalculates automatically since it's generated.
- **Nothing is stored in browser localStorage manually** — session persistence is entirely handled by the Supabase JS SDK.
