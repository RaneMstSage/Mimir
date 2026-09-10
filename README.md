# Inspect Element (Termux + Ruby)

Desktop-style Chrome DevTools for Chrome tabs on this tablet. See PLAN.md for the design
and TASKS.md for progress.

## Run
    inspect open      # start backend (if needed) and open the UI in the browser
    inspect status    # health + JSON status
    inspect stop

Backend: Sinatra on http://localhost:8765 (change with INSPECT_PORT).
State (paired flag, last adb port) lives in ~/.config/inspectelement/.

## First-time setup
1. Developer options → USB debugging ON, Wireless debugging ON.
2. Open http://localhost:8765/setup and Settings side by side (split-screen).
3. Wireless debugging → "Pair device with pairing code" → enter port + code in the app.
4. Tap "Auto connect". The Tabs page then lists Chrome tabs with Inspect buttons.
5. Browser menu → Add to Home screen to install as an app.
