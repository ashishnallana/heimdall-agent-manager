Drop screenshots here (PNG, dark theme): desktop captures >=1600px wide, phone captures 9:19-ish and >=720px wide.

Each slot in `../index.html` lists its images in the frame's `data-src` attribute (comma-separated, cycled in order), so that attribute is the source of truth for which files are used. Add a file here, then reference it from `data-src`; delete it here only after removing it from every `data-src`.

Until a file exists the page shows a labelled placeholder in its slot.
