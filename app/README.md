# tyzerrr.com

My personal blog: [https://tyzerrr.com](https://tyzerrr.com)

## Add a reading note

Create a Markdown file in `src/pages/readings/`. The file name becomes the page URL.

```md
---
layout: ../../layouts/ReadingPostLayout.astro
title: 'Book title'
bookAuthor: 'Author name'
publisher: 'Publisher name'
finishedDate: 2026-08-11
description: 'A short summary shown on the readings page.'
tags:
  - Go
  - Architecture
---

# What I learned

Write the reading note here.
```

Only `layout` and `title` are required. Reading notes are listed at `/readings/`, newest first by `finishedDate`.
