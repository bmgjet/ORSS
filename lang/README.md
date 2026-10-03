# Translations

Each `.json` file here is one language for Rom Sim Studio. The app reads this folder when it starts and offers every file in
**Settings > General > Language**. English is built in.

```json
{
  "language": "Deutsch",
  "english": "German",
  "author": "you",
  "strings": {
    "Save as…": "Speichern unter…",
    "Fuel cut": "Schubabschaltung"
  }
}
```

- The left side is the English text exactly as the app shows it; the right side is what to show instead.
- Anything not listed stays English, so a file can be partly done.
- A heading shown in capitals, a hotkey after a label ("Run (F5)"), a unit in brackets or an icon in front are matched to the
  plain text, so `"Run": "Start"` also covers "▶ Run (F5)".
- To make your own: copy a file, rename it (the file name, such as `nl.json`, is what Settings keeps) and edit it. Your own files
  can also go in the `lang` folder beside your settings (`%APPDATA%\RomSimStudio\lang`), where updates never overwrite them; a
  file there with the same name as one here adds to it and wins where both have a string.
- With a language picked, **Settings > General > Save the text not translated yet** writes the English text seen on screen with
  no translation to `missing-<language>.json` in your lang folder, ready to fill in.
