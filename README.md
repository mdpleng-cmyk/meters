# MDPL Meter Readings — Module Map

A reference for how the pieces fit together. Three files make up the whole system.

---

## 1. `schema.sql` — Database (Supabase / Postgres)

| Module | What it does |
|---|---|
| **`operators` table** | One row per person. `id` = matching Supabase Auth user UID. `code` builds their login email (`<code>@mdpl.local`). `level` (enum: `apprentice`, `operator`, `utility_operator`, `control_room`, `admin`) drives both which entry screen they see and what they're allowed to write — see the hierarchy table below. |
| **`meters` table** | Master list of physical meters: `meter_code`, `name`, `location`, `meter_group` (dashboard filtering), `unit`, `meter_type` (enum: `energy`/`hours`/`mass`/`volume`/`flow`/`other`), `reading_mode` (enum: `daily_round` / `shift_wise` — permanent per meter, never both), `cost_per_unit` (nullable — only meters with a real per-unit cost get one; leave blank for running-hours, pressure, etc.), `active` flag. |
| **`meter_readings` table** | One row per submitted reading. Stores `reading_value`, auto-filled `previous_reading`, a generated `consumption` column, who recorded it, `shift` (`Morning`/`Evening`/`Night`/`Round`), `reading_date`, and optional `notes` (flags a confirmed low/reset reading). |
| **`latest_meter_readings` view** | Returns just the most recent reading per meter — what the app queries to show "previous reading" on the entry screen. |
| **`set_previous_reading()` trigger** | Fires before every insert; looks up the last reading for that meter and stamps it into `previous_reading` automatically. |
| **`is_control_room_or_admin()` / `is_admin()` functions** | RLS helpers checking the logged-in user's `level`. |
| **RLS policies** | `operators`: names are public (needed for the login picker); only **Admin** can add/edit. `meters`: any logged-in user can read; only **Admin** can add/edit. `meter_readings`: any logged-in user can read; operators can only insert rows attributed to themselves (`auth.uid() = recorded_by`); only **Control Room or Admin** can edit/delete (fixing bad readings after the fact). |

### The operator hierarchy

| Level | Entry screen | Dashboard | Add/edit meters | Manage operators |
|---|---|---|---|---|
| Apprentice | Round tiles (no restrictions yet — placeholder for future task-specific limits) | — | — | — |
| Operator | Round tiles (daily 6 AM walk) | — | — | — |
| Utility Operator | Round tiles + shift selector (Morning/Evening/Night) | — | — | — |
| Control Room | — | ✓ view, fix/delete readings | — | — |
| Admin | — | ✓ everything Control Room has | ✓ | ✓ (helper panel — see below) |

---

## 2. `index.html` — Frontend (single file, no build step)

Everything lives in one file: HTML structure, hand-rolled dark theme (matches [[mdpl-telemetry-system]]'s look — Oswald/JetBrains Mono/Inter, amber accent), and one `<script>` block for logic.

| Section | What it does |
|---|---|
| **Config** | `SUPABASE_URL` / `SUPABASE_ANON_KEY` — the only two values you edit per deployment. |
| **State object** | Current operator (with `level`), meter list, tile-read tracking, modal state. Nothing persisted beyond the page session except the Supabase Auth session (handled by the SDK). |
| **Login flow** | Same as before: `initLogin()` → `loadOperatorPicker()` → PIN pad → `attemptLogin()` → `loadOperatorProfile()` (now selects `level` instead of the old `role`/`operator_type`). |
| **Level helpers** | `isRoundLevel()` (apprentice/operator), `isUtilityLevel()`, `isControlRoomOrAdmin()`, `isAdmin()` — every routing decision in the app reads through these instead of checking `level` inline. |
| **Tile View** (`refreshTileGrid()`) | The one entry screen for every reading-taking level. Round levels: flat grid of `daily_round` meters, "done" = read today (`shift = 'Round'`). Utility level: same grid mechanics but scoped to `shift_wise` meters, with a shift selector — "done" is per-shift, not per-day. Tapping a pending tile opens the reading modal. |
| **Reading modal** | Two-step: **Entry** (reading input, live consumption preview) → **Review** (shows entered reading, consumption, and estimated cost — only if the meter has `cost_per_unit` set — plus a low-reading warning if the value dropped) → **Confirm & Save** inserts the row, or **Edit** goes back. |
| **Control Room Dashboard** | Only shown to Control Room/Admin. Filters (date/shift incl. "Round"/group/search) → `refreshDashboard()` → `renderChecklist()` (read/pending per meter) → `renderLiveTable()` (raw feed) → realtime channel keeps both the dashboard and tile view in sync without a refresh → `exportCsv()`. |
| **Add Meter panel** (Admin only) | Form: code, name, location, group, type, unit, reading mode, optional cost per unit. Inserts directly into `meters` — live in the reading queue immediately, no deploy. |
| **Add Operator panel** (Admin only) | *Not* a live account-creation flow — creating a Supabase Auth user needs a service-role key, which can't safely live in a public HTML file, and calling public sign-up from the admin's own session would hijack it. Instead this generates the exact values (login email, PIN, and the `operators` row fields) for you to paste into the Supabase dashboard in two manual steps. |
| **Toast helper** | Save-confirmation / error popups. |

---

## 3. Migrations applied so far (run in this order on a fresh project)

1. **`schema.sql`** — base tables, trigger, view, seed data.
2. **`migration_level_hierarchy.sql`** — replaces `role` + `operator_type` with the single `level` column; rewrites RLS so Admin-only can write to `meters`/`operators`.
3. **`migration_enum_dropdowns.sql`** — converts `level`, `reading_mode`, and `meter_type` to native Postgres enums, so Table Editor renders them as dropdowns. (Note: the real column is `meter_type`, not `type` — an earlier version of this doc had it wrong.)
4. **`migration_fix_shift_constraint.sql`** — the original `shift` check constraint only allowed Morning/Evening/Night; extended to include `Round`.
5. **`migration_meter_cost.sql`** — adds the nullable `cost_per_unit` column used by the reading modal's estimated-cost display.

`migration_control_room.sql` (renamed `supervisor` → `control_room`) is now superseded by the level-hierarchy migration and only matters for archaeology.

---

## How a reading actually flows through the system

```
Operator taps name → PIN → Supabase Auth session created
        ↓
loadOperatorProfile() reads their `level`
        ↓
Round/Apprentice/Operator          Utility Operator
  → tile grid, done = today          → tile grid + shift picker, done = this shift
        ↓                                   ↓
              Tap a pending tile → reading modal
        ↓
Entry (input reading) → Review (consumption + cost if set + low-reading warning)
        ↓
Confirm & Save → INSERT into meter_readings
        ↓
   trigger stamps previous_reading automatically
   RLS checks recorded_by = auth.uid()
        ↓
Realtime broadcasts the change → tile grid AND Control Room dashboard update instantly
```

## Things to know for future changes

- **Level gate lives in two places**: the JS helper functions (`isRoundLevel()` etc.) and the DB functions (`is_admin()`, `is_control_room_or_admin()`). Change one, check the other.
- **`reading_mode` is permanent per meter** — a physical device needing more than one tracked value becomes multiple `meters` rows (same `meter_group`), not one meter with two modes.
- **Consumption is still a generated column** — never write to it directly.
- **The trigger only fires on INSERT**, not UPDATE — Control Room manually editing a `reading_value` later leaves that row's `previous_reading` as originally recorded.
- **`cost_per_unit` is optional and per-meter** — the modal only shows an estimated cost row when it's set; don't reintroduce a single global rate, since different meter types (kWh vs hours vs kg) aren't comparable.
- **Add Operator is intentionally manual** — the helper panel generates values, it doesn't call any API. If this ever needs to become fully automatic, it requires a Supabase Edge Function holding the service-role key server-side, not client-side code.
- **GitHub Pages needs the file named exactly `index.html`** — losing the extension makes Pages fall back to rendering this README instead of the app.
- **Nothing is stored in browser localStorage manually** — session persistence is entirely handled by the Supabase JS SDK.
