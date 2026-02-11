---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'About tyzerrr.com Tech Stack'
pubDate: 2026-02-05
description: 'An overview of the technologies used to build tyzerrr.com.'
author: 'tyzerrr'
---

I'm gonna show you the approach how to build this blog.  

Had some tradeoffs when I selected the framework, hosting-service, I hope you feel this helpful.

# Tech Stack

At first, I'm gonna show you technologies I use to build this site.

| Category | Technology|
|---|---|
| Framework | [Astro](https://astro.build/)
| Styling | [Tailwind CSS](https://tailwindcss.com/)
| Build Tool | [Vite](https://vite.dev/)
| Runtime | [Bun](https://bun.sh/)
| Hosting | [Cloudflare Pages](https://pages.cloudflare.com/)
| IaC | [Terraform](https://www.terraform.io/)


## Why Astro?
Workflow that I wanna achieve is below.
1. Write markdown, post content
2. Build and parse markdown to HTML on CI or hosting environment

To achieve point 2, I wanna to select the FW markdown well-supported.  
Also, Rendering speed is important.

Given all of them, Astro fits for me.
Astro is fast, easy to build, rich documentation.  
Also, this has bunch of plugins for code-hilighting, MDX.

## Why Cloudflare Pages?
Just wanted to give it a try.  
Since I'm not a **"Typescript-guy"**, I had never touched Cloudflare projects.  
For work, I use Google Cloud ( GKE, Spanner etc.. ), but that feels like **overengineering** for personal projects.

I've heard good things about Cloudflare's performance and wanted to test it firsthand.  
As it turns out, **it was the perfect fit.**


## Why Bun?
**Faster is better, simpler is better.**  
Bun is fast, because of using [JavascriptCore](https://developer.apple.com/documentation/javascriptcore), developed by Apple.
This is faster than [V8](https://v8.dev/) because Chromium-Transpiler and runtime is written in [Zig](https://ziglang.org/).

Also, bun is **all-in-one.**  
It has full Typescript support, bundler, test.  
I don't wanna waste my time to configure or add some libraries.

## Why Terraform?
No explanation.  
Infrastructure should be code.

# Wrap up
I built my tech blog with Typescript ecosystems.  
I've wanted to get the place to posts my technical journey, so happy.

This blog will serve as a place to document my technical journey, covering everything from professional challenges to personal experiments.

Bye.
