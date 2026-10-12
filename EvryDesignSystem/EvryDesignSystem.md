# Evry Design System

> Reference for building Evry (iOS and web). Extracted from the Evry marketing site (AlecWalt/EvrySite @ 50845df). Values are exact from the source; web units are CSS px, which map 1:1 to iOS points.

## How to use this file

- Use only the colours, type styles, radii and spacing named here. Don't invent new hues or fonts.
- Copy is calm, warm, sentence case, no emoji. Never call Evry an A‑I, bot or chatbot (see Content fundamentals).
- Image assets are in `Assets/` next to this file; add them to an asset catalog under the names given in the Assets section.
- A suggested SwiftUI mapping is at the end.

## Brand book

Evry is the calm all-in-one app for tasks, habits, notes, and your calendar, with Evry, a friendly star-shaped assistant, tying them together. The system is deliberately small: three colours, one typeface, soft round shapes, and a mascot with a lot of personality. Everything should feel calm, kind, and uncluttered.

### Content fundamentals

**Voice.** Warm, plain, and reassuring. Talk to the reader as *you*; the company speaks as *we* only in legal, FAQ, and contact copy. Evry, the assistant, speaks in the first person: “I found a free slot at 2:00 for ‘Write report.’ Add it?”

- Lead with calm, not productivity pressure: “Small routines, steady streaks.” “Kind reminders instead of nagging alerts.” “Celebrate progress without the pressure.”
- Sentence case everywhere: headings, buttons, eyebrows, nav (“Why Evry?”, “Get Evry free”, “Send message”).
- Buttons start with a verb and say what happens: “Download Evry”, “Try Pro”, “Send another message”.
- Contractions and light exclamations are welcome in conversational spots (“Nope! Evry is completely optional.”, “Thanks for saying hello!”), never in headings.
- Errors are polite and say how to fix it: “Please add your email so we can reply.” “That email doesn't look quite right.”
- Use curly quotes and apostrophes (’ “ ”) and the en dash for ranges (“Wed 2:00–4:00”).
- No emoji in UI or marketing copy.

**Naming Evry.** *Evry* is both the app and the assistant. Write it with a capital E, never “EVRY” or “evry” (the lowercase “evry” in the hero headline is a one-off typographic play inside “evrything”). Call Evry “your assistant” or “your friendly assistant”.

**Banned terms.** Never describe Evry with the words A‑I, artificial intelligence, machine learning, chatbot or bot, in copy, alt text or metadata. The repository's `npm run check:terms` fails the build on them. Describe what Evry *does* instead: “connects them so your plans just work”.

**Placeholders.** Anything unconfirmed (prices, store links, testimonials) is marked with a `PlaceholderTag` and `[X]` in copy, so nothing ships by accident.

### Visual foundations

#### Colour: strict 60‑30‑10

Only three colours exist; Tailwind's default palette is switched off.

- `white` (60%): page backgrounds, cards, fields.
- `sky` (30%): alternating sections, highlights, bullets, check discs, badges, the button on navy.
- `navy` (10%): all text, primary buttons, the footer and the CTA band, icons, the focus ring.

Make every other shade from these three, never a new hue: opacity steps of navy (`navy-80` … `navy-08`) and white (`white-85` … `white-10`), plus the mixed tints `sky-soft`, `sky-mist` and `navy-soft`.

- Set text in `navy` on `white`, `sky`, `sky-soft` and `sky-mist`; use `white` or `white-85` on `navy`.
- Secondary copy is `navy-80`. Never go lighter than `navy-75` for text: it is the AA floor on sky.
- Never set `sky` as text on white (1.35:1). The hero's sky “evry” is a documented, decorative exception inside a heading that still reads without it.
- Sections alternate tones top to bottom: `white`, `sky-mist`, `sky`, and one `navy` band near the end. A navy area carries the `on-navy` class so its focus ring flips to `focus-ring-on-navy`.
- Glows are soft radial gradients of `sky-glow` fading to nothing, placed off-canvas behind the hero and the CTA band. No other gradients.

#### Type

Nunito is the only typeface (variable, weights 400–800, Latin subset, loaded from Google Fonts with `display: swap`). Its rounded terminals carry the friendly tone, so never pair it with a second family.

- One `text-display` h1 per page, then `text-h2` per section and `text-h3` for card and plan titles. The three headline sizes are fluid `clamp()`s from 375px to 1440px; the token shows the 1440px size.
- Headlines are heavy (800) and tight (-0.02em); body text is 400 at line-height 1.6. Bold (700) is for labels, questions, nav and buttons, never for whole paragraphs.
- Put `text-lead` in `navy-80` under every section heading, at most about 42rem wide.
- Headings use `text-wrap: balance`; paragraphs `text-wrap: pretty`.
- The wordmark is `text-wordmark`: “Evry” at 24px, 800, +0.03em.

#### Shape and radius

Everything is soft. Buttons, eyebrows, badges, chips and bullets are full pills (`radius-pill`). Containers step up in radius with their size: `radius-field` (16px) for fields, store buttons and bubbles, `radius-card` (24px) for cards, `radius-panel` (32px) for plan cards, `radius-band` (40px) for the CTA band. Nothing is square.

#### Depth

Cards sit on `white` with a `navy-08` hairline and `shadow-soft`; hover lifts them 3px to `shadow-lift`. Shadows are always navy-tinted, never black. Primary buttons carry `shadow-btn`. The mascot casts `shadow-mascot` as a `drop-shadow` filter. Use a card only for a self-contained object (a plan, a question, a form); section content sits directly on the section tone.

#### Layout

- Content sits in `.container-page`: `space-container` (1216px) max, `space-gutter` 16px sides, `space-gutter-md` 32px from 768px.
- Every section has `space-section` (64px) vertical padding, `space-section-lg` (112px) from 1024px.
- Section headings are centred by default, with `space-heading` below. Grids use `space-grid` gaps and collapse to one column on phones.
- Every tap target is at least `space-tap` (44px); buttons are `space-btn-height` (48px).

#### Motion

Motion is playful but never in the way. The house curve is `ease-settle`; overshoot (`ease-spring`) is reserved for the mascot and small delights.

- Buttons rise 1px on hover, cards 3px, both over `duration-hover` / `duration-card`.
- Content reveals on scroll: fade in and rise 14px over `duration-reveal`. Content is only hidden once JavaScript has marked the page, so nothing vanishes without it.
- Items “pop” in (scale from 0.3 with a small overshoot) over `duration-pop`, staggered.
- The mascot floats (`duration-float`), blinks (`duration-blink`) and tilts −8° on hover.
- `prefers-reduced-motion: reduce` switches every animation and hover transform off, and reveals show content immediately. Always honour it.

#### States

- **Focus:** a 3px solid `focus-ring` outline, 3px offset, `radius-focus` corners, on every interactive element; `focus-ring-on-navy` inside navy areas.
- **Hover:** primary button turns `navy-soft`; secondary fills `sky-soft` and darkens its border to `navy-28`; links take a full navy underline; nav items fill `sky-mist`.
- **Current page:** the nav item fills `sky-soft`.
- **Error:** fields turn their border full `navy` and show a bold `text-sm` message with the alert icon underneath. There is no red: errors are carried by the icon and words.
- **Disabled / not yet available:** store buttons keep their look and read “Coming soon to”; they are not links.

### Iconography

Icons are inline SVG line glyphs on a 24×24 grid (some utilities on 20 or 16), stroke 2, round caps and joins, drawn in `currentColor`, so they take `navy` from the text around them. The uploaded copies in **Icons** have the navy ink baked in, since an `<img>` cannot inherit colour.

- Each tool has its own glyph *and* its own tile shape, so tools differ by form, not by new colour: **Tasks** a rounded square in `sky`; **Habits** a circle in sky at 70%; **Notes** a folded sheet in sky at 45% with a clipped corner; **Calendar** a white tile with a 2px `navy` ring. See `ToolIcon`.
- The star glyph (`evry.svg`) stands for Evry, the assistant, in small UI.
- Bullets are a plain 12px `sky` dot; feature lists use `Check` (a sky disc with a navy tick).
- Store buttons use the Apple and Google Play glyphs as single-colour silhouettes.
- No emoji, no icon fonts.

### The mascot

Evry is a soft, slightly lopsided white star with two big navy eyes and a sky offset shadow. The mascot is the brand's main image: use it wherever a page needs warmth (hero, CTA band, empty and success states, the featured plan).

- Use `evry.png` (transparent cutout, 960×923). Never redraw, recolour, stretch or crop it.
- On sky backgrounds, sit Evry on a white disc so the sky shadow stays visible.
- The header and footer use the plain outline mark (`evry-plain-mark.png`) next to the wordmark.
- The animated version is a Rive file (`public/mascot/evry.riv` in the site) with idle, blink and a happy hover state; the PNG stands in until it loads and for reduced motion.
- Give Evry `alt=""` when the words next to it already say what it is; otherwise describe the pose (“Evry, waving you in”).

### Components

The specs in the Components section below describe the site's own building blocks. On iOS, rebuild them natively with the tokens; keep the same names so web and app stay in step.

### Not synced

- Colour values written with `color-mix()` in the source (`sky-soft`, `sky-mist`, `navy-soft`) are stored as their resolved hex.
- Fluid `clamp()` sizes are stored at their 1440px maximum; the clamp is in each style's note.
- Nunito is hosted by Google Fonts; no font file is stored.
- The Rive animation (`evry.riv`) and its engine are not uploaded (not a supported asset type).
- Page-specific animations (the scattered-to-sorted story, star rating, feature demos, Meet Evry) and the phone mockups are not components here.
- Components are static renditions hand-written from the source paths in each README; there is no runnable component bundle.

## Tokens

### Colours

| Token | Value | Use |
| --- | --- | --- |
| `white` | `#ffffff` | The 60 of the 60-30-10 palette: page backgrounds, cards, form fields. Also the label colour on navy fills. |
| `sky` | `#b0e6ff` | The 30: alternating sections, highlights, bullets, check discs, the featured-plan badge and the button on navy. Never text on white (1.35:1); navy on sky reads at 11.7:1. |
| `navy` | `#162339` | The 10: all text, primary buttons, the footer and CTA band, key icons, the focus ring. 15.7:1 on white, 11.7:1 on sky. |
| `sky-soft` | `#e3f6ff` | Resolved from color-mix(in srgb, sky 35%, white). Hover fill for secondary buttons, eyebrow pills, Evry's speech bubble, the FAQ plus disc. |
| `sky-mist` | `#f1fbff` | Resolved from color-mix(in srgb, sky 18%, white). The faintest tint: the 'mist' section tone, FAQ summary hover, the suggestion panel in the hero mockup. |
| `navy-soft` | `#283a51` | Resolved from color-mix(in srgb, navy 88%, sky). Primary button hover only. |
| `navy-80` | `rgba(22, 35, 57, 0.8)` | Secondary copy: lead paragraphs, card body, FAQ answers. 8.3:1 on white, 6.8:1 on sky. |
| `navy-75` | `rgba(22, 35, 57, 0.75)` | The lightest text allowed: captions, price periods, '(optional)' hints. 7.0:1 on white, 5.9:1 on sky. Never go lighter for text. |
| `navy-60` | `rgba(22, 35, 57, 0.6)` | Form placeholder text only. 4.27:1 on white: below AA 4.5:1 as the source has it; flagged, keep placeholders as hints and never as the only label. |
| `navy-40` | `rgba(22, 35, 57, 0.4)` | Dashed border of the placeholder tag. |
| `navy-30` | `rgba(22, 35, 57, 0.3)` | Resting underline of text links (turns full navy on hover). |
| `navy-28` | `rgba(22, 35, 57, 0.28)` | Secondary button border on hover. |
| `navy-20` | `rgba(22, 35, 57, 0.2)` | Resting border of text fields and selects (1.5:1 on white: below the 3:1 control-border floor in the source; the field turns full navy on focus and on error). |
| `navy-16` | `rgba(22, 35, 57, 0.16)` | Secondary button border at rest. Also the 15% ring on small 'Not now' chips. |
| `navy-08` | `rgba(22, 35, 57, 0.08)` | Card hairline border. |
| `white-85` | `rgba(255, 255, 255, 0.85)` | Body copy on navy (CTA band, featured plan). 11.7:1 on navy. |
| `white-80` | `rgba(255, 255, 255, 0.8)` | Muted text on navy (price period on the featured plan). 10.5:1 on navy. |
| `white-60` | `rgba(255, 255, 255, 0.6)` | Ghost-light button border on hover. |
| `white-35` | `rgba(255, 255, 255, 0.35)` | Ghost-light button border at rest, on navy. |
| `white-10` | `rgba(255, 255, 255, 0.1)` | Ghost-light button hover fill, on navy. |
| `sky-glow` | `rgba(176, 230, 255, 0.55)` | Centre of the soft radial glow behind the hero (fades to sky at 0). On the navy CTA band the same glow runs at 0.16. |
| `page` | `{white}` | Alias: the page background. |
| `ink` | `{navy}` | Alias: default text colour on white, sky, sky-soft and sky-mist. |
| `focus-ring` | `{navy}` | Alias: 3px solid outline, 3px offset, on every light surface. |
| `focus-ring-on-navy` | `{sky}` | Alias: the focus ring inside navy areas (.on-navy). 11.7:1 on navy. |

### Type

Family: **Nunito** (Google Fonts, variable 400–800). Fallback: system sans. On iOS bundle Nunito's variable TTF from Google Fonts and register it in Info.plist (`UIAppFonts`).

| Style | Size | Line height | Weight | Tracking | Use |
| --- | --- | --- | --- | --- | --- |
| `text-display` | 72px | 1.08 | 800 | -0.02em | The page's one h1. Fluid: clamp(2.5rem, 1.8rem + 3vw, 4.5rem), 40px at 375px wide to 72px at 1440px. |
| `text-h2` | 48px | 1.15 | 800 | -0.015em | Section headings and the CTA band. Fluid: clamp(2rem, 1.65rem + 1.5vw, 3rem), 32px to 48px. |
| `text-h3` | 28px | 1.2 | 700 | 0 | Card and plan titles, h2 inside blog posts. Fluid: clamp(1.375rem, 1.24rem + 0.56vw, 1.75rem), 22px to 28px. |
| `text-title` | 19px | 1.3 | 600 | 0 | Small titles inside cards and tool tiles. |
| `text-lead` | 20px | 1.6 | 400 | 0 | The paragraph under a heading, in navy-80. Fluid: clamp(1.125rem, 1.08rem + 0.2vw, 1.25rem), 18px to 20px. |
| `text-body` | 16px | 1.6 | 400 | 0 | All running text. Bold (700) for labels, FAQ questions and button text. |
| `text-bubble` | 15px | 1.625 | 400 | 0 | Speech bubbles (EvryBubble md). The sm bubble is 13px / 1.375. |
| `text-sm` | 14px | 1.43 | 700 | 0 | Eyebrows, field errors, the small print under pricing (at 400). |
| `text-xs` | 12px | 1.33 | 700 | 0 | Badges, placeholder tags, store-button sublabels (600). |
| `text-wordmark` | 24px | 1 | 800 | 0.03em | The wordmark beside the plain mark in the header and footer. Always the word Evry, capital E. |
| `text-price` | 48px | 1 | 800 | -0.025em | Plan prices, followed by the period in 16px 600 navy-75. |

### Spacing

| Token | Value | Use |
| --- | --- | --- |
| `space-container` | `1216px` | max-width of .container-page (76rem). Also the CTA band's max width. |
| `space-gutter` | `16px` | Page side padding below 768px. |
| `space-gutter-md` | `32px` | Page side padding from 768px. |
| `space-section` | `64px` | Vertical padding of every Section (.section-y) below 1024px. |
| `space-section-lg` | `112px` | Vertical padding of every Section from 1024px. |
| `space-heading` | `40px` | Gap under a SectionHeading (56px from 1024px). |
| `space-grid` | `24px` | Gap between cards in a grid, and between form rows. |
| `space-card` | `28px` | Inner padding of plan cards (36px from 640px). Forms: 24px, 36px from 640px. |
| `space-btn-x` | `24px` | Button side padding. |
| `space-btn-y` | `12px` | Button vertical padding. |
| `space-btn-height` | `48px` | Minimum button height. |
| `space-tap` | `44px` | Smallest tap target anywhere (header logo, nav links). Checked by check:widths. |
| `space-store-height` | `56px` | Minimum height of an app store button and FAQ summary row. |
| `space-scroll-offset` | `96px` | scroll-padding-top, so anchors clear the sticky header. |

### Radius

| Token | Value | Use |
| --- | --- | --- |
| `radius-pill` | `9999px` | Buttons, eyebrows, badges, chips, placeholder tags, bullets. |
| `radius-band` | `40px` | The navy CTA band. |
| `radius-panel` | `32px` | Plan cards and other large panels. |
| `radius-card` | `24px` | Cards, FAQ items, forms, blog covers. |
| `radius-field` | `16px` | Text fields, selects, store buttons, speech bubbles, inset panels (rounded-2xl). |
| `radius-tile` | `12px` | Tool icon tiles (rounded-xl). The Notes tile cuts its top-right corner to 5.6px. |
| `radius-focus` | `8px` | Corner of the focus outline. |
| `radius-tail` | `6px` | The speech-bubble corner that points at the speaker (bottom-left for Evry, bottom-right for you). |

### Shadows

| Token | Value | Use |
| --- | --- | --- |
| `shadow-soft` | `0 1px 2px rgba(22, 35, 57, 0.05), 0 8px 24px -8px rgba(22, 35, 57, 0.12)` | Resting card. |
| `shadow-lift` | `0 2px 4px rgba(22, 35, 57, 0.06), 0 18px 40px -12px rgba(22, 35, 57, 0.2)` | Hovered card, open FAQ item, featured plan. |
| `shadow-device` | `0 30px 60px -20px rgba(22, 35, 57, 0.35), 0 0 0 1px rgba(22, 35, 57, 0.06)` | Phone mockups. |
| `shadow-btn` | `0 6px 16px -6px rgba(22, 35, 57, 0.45)` | Primary button at rest. |
| `shadow-btn-hover` | `0 10px 22px -8px rgba(22, 35, 57, 0.5)` | Primary button on hover. |
| `shadow-mascot` | `0 18px 24px rgba(22, 35, 57, 0.18)` | Applied as filter: drop-shadow() under the floating hero mascot, so it follows the star's outline. |

### Durations

| Token | Value | Use |
| --- | --- | --- |
| `duration-hover` | `200ms` | Buttons and links: transform, shadow, colour. |
| `duration-card` | `250ms` | Card lift on hover. |
| `duration-pop` | `500ms` | Items popping in (week plan, tools, Meet Evry). |
| `duration-reveal` | `700ms` | Scroll reveal: fade plus a 14px rise. |
| `duration-float` | `6s` | The mascot's float loop: 10px up and -1.5deg at the midpoint. |
| `duration-blink` | `5.5s` | The mascot's blink loop. |

### Easing

| Token | Value | Use |
| --- | --- | --- |
| `ease-settle` | `cubic-bezier(0.2, 0.8, 0.2, 1)` | The house curve: reveals, pops, demo transitions. Fast out, soft landing. |
| `ease-spring` | `cubic-bezier(0.3, 1.4, 0.5, 1)` | Playful overshoot: mascot tilt, squish, hints. |
| `ease-bounce` | `cubic-bezier(0.3, 1.6, 0.5, 1)` | Rating stars' hover bump. |

## Components

Each spec below is from the web site's components. Rebuild them natively with the same tokens.

### Bullet

The site's bullet point: a plain 12px `sky` dot. Hand-written from `Bullet` in `components/ui/primitives.tsx` and `.prose-evry ul` in `app/globals.css`.

Use it for every ordinary bulleted list; the dot sits 0.45em from the top of the first line, 12px before the text. The consumer supplies the list items. For included-feature lists use `Check` instead.

### Button

A pill-shaped link or button with four variants. Hand-written from `app/globals.css` (`.btn`, `.btn-*`) and `ButtonLink` in `components/ui/primitives.tsx`.

- **primary** (`navy`, white label, `shadow-btn`): the one action the view is for, such as “Download Evry”. Hover turns `navy-soft` and rises 1px.
- **secondary** (white, `navy-16` border): the alternative next to a primary, such as “Meet Evry →”. Hover fills `sky-soft`.
- **sky**: the primary action on a navy surface (the featured plan's “Try Pro”). Hover turns white.
- **ghost-light**: a secondary action on navy (`white-35` border).

The consumer supplies `href`, the variant and the label. Labels are sentence case and start with a verb. A trailing arrow-right icon marks “go somewhere to learn more”. Buttons are at least 48px tall; on phones, stack them full-width (`flex-col`) and switch to a row from 640px. Use at most one primary per view.

### Card

The white surface for a self-contained object. Hand-written from `.card` and `.card-hover` in `app/globals.css`.

`white` fill, 1px `navy-08` border, `radius-card` (24px) corners, `shadow-soft`. Add `card-hover` when the whole card is a link: it rises 3px to `shadow-lift` over `duration-card`.

The consumer supplies the padding (24px on phones, 36px from 640px is typical) and content. Use cards for plans, FAQ items, forms and blog posts; don't wrap ordinary section content in cards. For large panels use `radius-panel` (32px).

### Check

A sky disc with a navy tick, for “what's included” lists. Hand-written from `Check` in `components/ui/primitives.tsx`.

20px, the disc in `sky`, the tick in `currentColor` (keep it `navy`, also on the navy featured plan). The consumer supplies the item text. Use it in plan feature lists and comparison tables, not for ordinary bullets.

### CtaBand

The closing download call to action: a rounded navy band with the store buttons and a floating mascot. Hand-written from `components/sections/CtaBand.tsx`.

- `navy` panel, `radius-band` (40px), max `space-container`, with a soft `sky` glow off its bottom-right corner.
- Left: `text-h2` title, `text-lead` in `white-85`, light `StoreButtons`. Right: the mascot, floating. Stacks to one column below 768px.
- It sits on a white section with 64px (96px from 1024px) padding and carries `id="download"` so every “Download Evry” button can link to `/#download`.

The consumer may override `title` and `body`. Use it once per page, last before the footer.

### EvryBubble

A conversation line: Evry's avatar beside a sky speech bubble, or the person's message in navy on the right (`UserBubble`). Hand-written from `components/mascot/EvryBubble.tsx`.

- **Evry**: mascot avatar (40px; 28px at `sm`), `sky-soft` bubble with a 1px `sky` ring, `radius-field` corners except a `radius-tail` bottom-left that points at Evry.
- **You**: `navy` bubble, white text, right-aligned, max 85% wide, tail bottom-right.
- Text is 15px / 1.625 (`text-bubble`); `sm` is 13px / 1.375 for use inside phone mockups.
- Each bubble starts with a visually hidden “Evry says:” or “You:” for screen readers.

The consumer supplies the message and size. Evry's lines are short, first person, friendly, and usually end with an offer (“Add it?”, “Shall I add a reminder?”).

### Eyebrow

A small sentence-case pill label above a heading. Hand-written from `Eyebrow` in `components/ui/primitives.tsx`.

`sky-soft` fill with a 1px `sky` ring, `radius-pill`, 14px bold navy. The consumer supplies two to four words. Use one per section heading at most; never uppercase it, and never use it as a button.

### FaqList

An accordion of questions built on native `<details>`, so it works without JavaScript. Hand-written from `components/sections/FaqList.tsx`.

Each item is a `Card`; the summary row is at least 56px, bold, fills `sky-mist` on hover, and ends in a 32px `sky-soft` disc with a plus that turns 45° into a cross when open. An open item lifts to `shadow-lift`. Answers are `navy-80`.

The consumer supplies `{ q, a }` items. Questions are phrased the way a person would ask them; answers start with a direct yes or no where they can.

### FormField

A labelled text field, select or textarea with its inline error. Hand-written from `components/sections/ContactForm.tsx`.

- Label: bold, above the field; optional fields add “(optional)” in 600 `navy-75`.
- Field: white, 1.5px `navy-20` border, `radius-field`, 12px × 16px padding, 16px text (prevents zoom on iOS). Focus turns the border `navy` and adds the 3px focus ring.
- Error: the border turns `navy`, `aria-invalid` is set, and a bold 14px message with the alert icon sits 8px below, linked by `aria-describedby`. On submit, focus moves to the first invalid field.
- Placeholders are `navy-60` (4.27:1, under AA as in the source): use them as examples only, never instead of a label.

The consumer supplies `id`, `name`, the label, the error message and `autocomplete`. Error messages say “please” and how to fix it.

### Logo

The plain Evry mark beside the “Evry” wordmark, always linking home. Hand-written from `components/layout/Logo.tsx`.

- Mark: `evry-plain-mark.png` (the sky star outline) at 36px wide; the full mascot can stand in (`mark="mascot"`).
- Wordmark: `text-wordmark` (24px, 800, +0.03em), `navy`, or `white` in the footer.
- 10px gap; the link is at least 44px tall and labelled “Evry home”. The mark tilts −8° on hover.

The consumer supplies `tone` (`navy` or `white`) and `mark`. Never set the wordmark in another face or recolour the mark.

### Mascot

Evry, the white star, as an image with optional float, blink and hover tilt. Hand-written from `components/mascot/Mascot.tsx`.

- Source: `evry.png` (960×923, transparent). The site animates it with Rive (`evry.riv`: idle, blink, and a happy hover state) and falls back to the PNG.
- Options in the site: `float` (6s bob, `duration-float`), `blink`, `tilt` (−8° on hover with `ease-spring`), `disc` (a white circle behind, required on `sky` so the star's sky shadow stays visible), `animated`.
- Under the hero, add `shadow-mascot` as a `drop-shadow` filter.
- All motion stops under `prefers-reduced-motion`.

The consumer supplies the size and `alt` (empty when nearby text names Evry). Never crop, recolour, rotate statically or put text on the mascot.

### PlaceholderTag

A dashed pill that marks content still to be replaced before launch. Hand-written from `PlaceholderTag` in `components/ui/primitives.tsx`.

White, 1px dashed `navy-40` border, 12px bold, with the pencil icon. The consumer supplies a short label (default “Placeholder”). Put it next to every unconfirmed price, limit, testimonial or link, and remove it with the placeholder.

### PricingTier

A plan card: name, blurb, price, included features and a full-width button. Hand-written from `components/sections/PricingTiers.tsx`.

- Standard plan: a `Card` with `radius-panel` corners and a primary button.
- Featured plan: `navy` with white text and `shadow-lift`, a `sky` “More help from Evry” badge, a sky button, and the mascot perched over the top-right corner.
- Price in `text-price` (48px, 800) with the period in 600 `navy-75` (`white-80` on navy). Features use `Check`.
- Padding `space-card` (28px; 36px from 640px). Two plans sit side by side from 768px.

The consumer supplies `name`, `price`, `period`, `blurb`, `features`, `cta` and `featured`. Prices in the site are placeholders; mark them with `PlaceholderTag` until confirmed.

### Section

A full-width page band with the site's vertical rhythm and one of four tones. Hand-written from `Section` in `components/ui/primitives.tsx`.

- Tones: `white` (default), `mist` (`sky-mist`), `sky`, `navy` (adds `on-navy`, white text).
- Padding: `space-section` (64px) top and bottom, `space-section-lg` (112px) from 1024px (`.section-y`).
- Put a `.container-page` inside (1216px max, 16px / 32px gutters).

The consumer supplies the tone and children, usually a `SectionHeading` and content. Alternate tones down the page so neighbours never share one; keep sky to one or two sections and navy to one.

### SectionHeading

The heading block that opens a section: optional eyebrow, an h2, and a lead paragraph. Hand-written from `SectionHeading` in `components/ui/primitives.tsx`.

- `text-h2` title; `text-lead` in `navy-80`, 16px below; eyebrow 16px above.
- Centred by default (`align="center"`), max 42rem wide; `align="left"` for split layouts.
- `space-heading` (40px, 56px from 1024px) below it.

The consumer supplies `title`, optional `eyebrow`, optional children (the lead) and an `id` for `aria-labelledby`. It reveals on scroll.

### StoreButtons

App Store and Google Play download buttons. Hand-written from `components/ui/StoreButtons.tsx`.

- **navy** (default) on light sections; **light** (white fill, navy text) inside the navy CTA band.
- Each button is a 56px-tall `radius-field` tile: the store glyph, a 12px 600 sublabel (“Download on the”, “Get it on”) over a 16px bold store name.
- Until a store is live, the sublabel reads “Coming soon to”, the element is a `span` (not a link) with an `aria-label` ending “link coming soon”, and there is no hover lift.

The consumer supplies each store's `href` and whether it is available. Swap in official badge artwork when you have it.

### TextLink

An inline link with a soft, thick underline. Hand-written from `.link` in `app/globals.css`.

Bold, current text colour, 2px underline in `navy-30` with a 4px offset; the underline turns full colour on hover. The consumer supplies `href` and the words. Link text says where it goes (“pricing page”), never “click here”.

### ToolIcon

A tool's glyph inside that tool's own tile shape. Hand-written from `components/ui/ToolIcon.tsx`.

Tools differ by shape and fill strength, never by new colours:

| Tool | Tile |
| --- | --- |
| Tasks | rounded square (`radius-tile`), `sky` |
| Habits | circle, sky at 70% |
| Notes | rounded square with a 5.6px top-right corner, sky at 45% |
| Calendar | rounded square, `white` with a 2px `navy` ring |

Sizes: `md` 48px tile with a 24px glyph, `sm` 32px with 18px. The consumer supplies the tool id (`tasks`, `habits`, `notes`, `calendar`) and size. Always pair it with the tool's name in text; the tile is decorative (`aria-hidden`).

## Assets

### Logos

- `evry-plain-mark.png` — The plain mark: Evry's star outline as a flat `sky` (#b0e6ff) shape, 1098×1074, transparent. Used at 36px beside the wordmark in the header and footer. There is no wordmark file: set “Evry” in `text-wordmark`.
- `evry-app-icon.png` — Favicon, 256×256, the mascot cutout on transparent.
- `evry-apple-touch-icon.png` — Home-screen icon, 180×180, the mascot on a white square.

### Mascot

- `evry.png` — Evry, the cutout used across the site: a white star with navy (#162339) eyes and a sky (#b0e6ff) offset shadow, 960×923, transparent. Use this one.
- `evry-source-artwork.png` — The original artwork on its solid dark background, kept as the source for `scripts/prepare-mascot.mjs`. Don't place it in layouts.

The animated Rive version (`evry.riv`) lives in the site at `public/mascot/evry.riv`.

### Icons

Line glyphs copied from `components/ui/ToolIcon.tsx` and `components/ui/primitives.tsx`. Stroke 2, round caps and joins. In code they draw in `currentColor`; these files have the ink baked in as `navy` (#162339), because an `<img>` cannot inherit colour.

- `tasks.svg`, `habits.svg`, `notes.svg`, `calendar.svg` — The four tools (24×24). Show them inside their tile shapes, see `ToolIcon`.
- `evry.svg` — The star that stands for Evry, the assistant, in small UI (24×24).
- `arrow-right.svg` — Trailing arrow in “learn more” buttons (20×20).
- `check.svg` — Included-feature tick: a `sky` disc with a navy tick (20×20).
- `plus.svg` — FAQ open/close; rotates 45° when open (16×16).
- `pencil.svg` — Inside `PlaceholderTag` (16×16).
- `alert.svg` — Before a form field error (16×16, solid).

Suggested asset-catalog names: `EvryMascot` (evry.png), `EvryPlainMark` (evry-plain-mark.png), `EvryAppIcon` (evry-app-icon.png). The icons are SVGs: import with “Preserve Vector Data” and “Render As: Template Image” so they tint with `.foregroundStyle`, or use the closest SF Symbols (`checkmark.square`, `arrow.clockwise.circle`, `doc.text`, `calendar`, `star`, `arrow.right`, `checkmark.circle.fill`, `plus`, `pencil`, `exclamationmark.circle.fill`).

## SwiftUI mapping (suggested)

```swift
import SwiftUI

extension Color {
    // 60-30-10: white, sky, navy. Everything else is an opacity of these.
    static let evryWhite = Color(red: 1, green: 1, blue: 1)                       // #ffffff
    static let evrySky   = Color(red: 176/255, green: 230/255, blue: 255/255)     // #b0e6ff
    static let evryNavy  = Color(red: 22/255,  green: 35/255,  blue: 57/255)      // #162339
    static let evrySkySoft  = Color(red: 227/255, green: 246/255, blue: 255/255)  // #e3f6ff
    static let evrySkyMist  = Color(red: 241/255, green: 251/255, blue: 255/255)  // #f1fbff
    static let evryNavySoft = Color(red: 40/255,  green: 58/255,  blue: 81/255)   // #283a51
    static let evryTextSecondary = evryNavy.opacity(0.8)   // navy-80
    static let evryTextMuted     = evryNavy.opacity(0.75)  // navy-75, the lightest text allowed
    static let evryHairline      = evryNavy.opacity(0.08)  // card border
}

enum EvryRadius {
    static let field: CGFloat = 16, card: CGFloat = 24, panel: CGFloat = 32, band: CGFloat = 40, tile: CGFloat = 12, tail: CGFloat = 6
}

enum EvrySpace {
    static let gutter: CGFloat = 16, grid: CGFloat = 24, card: CGFloat = 28, buttonHeight: CGFloat = 48, tap: CGFloat = 44
}

extension Font {
    // Register Nunito (variable) in Info.plist first.
    static func evry(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Nunito", size: size).weight(weight)
    }
    static let evryDisplay = evry(40, .heavy)   // text-display on phone widths (72 on large screens), tracking -0.02em
    static let evryH2      = evry(32, .heavy)   // text-h2 on phone widths (48 large), tracking -0.015em
    static let evryH3      = evry(22, .bold)    // text-h3 on phone widths (28 large)
    static let evryTitle   = evry(19, .semibold)
    static let evryLead    = evry(18)           // 18-20, line height 1.6
    static let evryBody    = evry(16)
    static let evryBubble  = evry(15)
    static let evrySmall   = evry(14, .bold)
    static let evryCaption = evry(12, .bold)
}

// Primary button: navy pill, white bold label, soft navy shadow.
struct EvryPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.evry(16, .bold))
            .foregroundStyle(Color.evryWhite)
            .padding(.horizontal, 24)
            .frame(minHeight: EvrySpace.buttonHeight)
            .background(configuration.isPressed ? Color.evryNavySoft : Color.evryNavy, in: Capsule())
            .shadow(color: Color.evryNavy.opacity(0.45), radius: 8, y: 6)
    }
}

// Card: white, 24pt corners, navy hairline, soft navy shadow.
struct EvryCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.evryWhite, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).stroke(Color.evryHairline, lineWidth: 1))
            .shadow(color: Color.evryNavy.opacity(0.12), radius: 12, y: 8)
    }
}
```

Motion on iOS: use `.spring(response: 0.5, dampingFraction: 0.8)` for the house “settle” curve and a bouncier spring for the mascot; skip all decorative motion when `@Environment(\.accessibilityReduceMotion)` is true. The site is light-only; there is no dark palette yet.
