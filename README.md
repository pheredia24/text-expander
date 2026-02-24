# Expander (macOS)

System-wide text expansion for macOS apps. Define abbreviations and have them expanded as you type.

## Run (Package Mode Recommended)

Build a real `.app` bundle and install it to `~/Applications`:

```bash
./scripts/build-app.sh --install
open ~/Applications/Expander.app
```

You can also build without installing:

```bash
./scripts/build-app.sh
open ./dist/Expander.app
```

## Run (Terminal Mode)

```bash
swift run --disable-sandbox
```

Or build once and run the binary directly:

```bash
swift build --disable-sandbox
./.build/arm64-apple-macosx/debug/TextExpander
```

## Permissions

To expand text in other applications, macOS permissions are required:

1. Open **System Settings > Privacy & Security > Accessibility**
2. Add/enable **Expander.app** from `~/Applications`
3. Open **System Settings > Privacy & Security > Input Monitoring**
4. Add/enable **Expander.app** from `~/Applications`
5. Relaunch Expander after enabling both permissions

If you use terminal mode (`swift run`), permissions may apply to **Terminal** instead.

The app includes buttons to request both Accessibility and Input Monitoring prompts.

## Behavior

- Type an abbreviation (example: `sig`)
- Type a delimiter (space, enter, punctuation)
- The app deletes the abbreviation and inserts the configured phrase
- Snippets are persisted in `UserDefaults`
- Menu bar icon provides quick enable/disable, open window, and quit
- Snippets support JSON import/export

## Optional: Start At Login

After installing `~/Applications/Expander.app`, add it to:

1. **System Settings > General > Login Items**
2. Add **Expander**
