# docmost.nvim

A Neovim plugin for my self-hosted [Docmost](https://docmost.com). I browse and search
my spaces from Neovim, every page opens as a Markdown buffer, and `:w` saves it back.

It signs in with a normal user session and talks to the same internal endpoints the
web app uses, so no enterprise API key is needed.

## Why

I have been self-hosting Docmost for a while, and editing in the browser always
annoyed me. For anything longer than a quick fix I wrote the page in Neovim as
Markdown and imported it later, whenever I got around to it. An import creates a new
page though, so fixing an existing one meant copying it out and pasting it back.

Now I open the page from Neovim, edit it, and save.

## What a page looks like

```markdown
---
title: Release plan
---

# Release plan

Owner [@Marcos]{.mention x-id="u1"}, see [the thread]{.comment commentId="c1"}.

::: {.callout type="warning"}
Freeze on **Friday**.
:::

- [x] Tag release
- [ ] Announce

| Service | Status |
| --- | --- |
| api | green |
```

Docmost does not store Markdown. It stores a JSON document, and its Markdown export
drops everything Markdown cannot say: mentions, comment anchors, attachments,
colours, alignment, merged table cells. Writing that export back would delete them.

So the plugin has its own format. Plain Markdown where it works, Pandoc's attribute
syntax for the rest. The `{...}` parts are hidden until the cursor is on the line,
so most of the time a page reads like normal Markdown. Blocks the plugin has never
seen use a generic `::: {.blockName}` form and come back unchanged, so every page is
editable.

## Install

Needs `curl` and `pandoc`. LuaSnip is optional, for snippets.

With lazy.nvim, add this to your plugins table. In NvChad that is
`lua/plugins/init.lua`:

```lua
{
  'mmrmagno/docmost.nvim',
  cmd = 'Docmost',
  opts = {
    base_url = 'https://docs.example.com',
    persist_session = true,
  },
},
```

`base_url` is the origin, without `/api`, and has to be HTTPS.

## Signing in

`:Docmost login`, or `a` in the workspace. The password goes through Neovim's secret
prompt and reaches curl over stdin, never as an argument, and it is never stored.

`persist_session = true` keeps the session cookie in `stdpath('state')/docmost/`
with mode 0600, so I stay signed in across restarts. How long that lasts is up to
the server: Docmost's `JWT_TOKEN_EXPIRES_IN`, 30 days by default. `:Docmost logout`
deletes the file.

For SSO, or to reuse the browser session, hand over the `authToken` cookie instead:

```lua
session_token = function() return vim.env.DOCMOST_SESSION_TOKEN end,
```

## Using it

`:Docmost` opens the workspace: spaces and pages as a tree, a preview of the
selected page next to it. Enter opens the page in the window I came from, and
`:Docmost` again brings the workspace back where I left it.

| Key | Action |
|---|---|
| `l` / `h` | Expand, collapse |
| Enter, `Ctrl-v`, `Ctrl-t` | Open here, in a split, in a tab |
| `/` | Search as you type |
| `p` | Toggle the preview |
| `.` | Everything you can do with the selected row |
| `a` / `L` | Sign in, sign out |
| `?` | All the keys |

In a page, `:w` saves. The winbar shows `saving`, `verifying`, then `verified`.
The `title:` line renames the page, a `#` heading only changes the body.

| Command | Action |
|---|---|
| `:Docmost open <url>` | Open a page directly |
| `:Docmost check` | Show mistakes as diagnostics, without saving |
| `:Docmost inspect` | Explain the block under the cursor |
| `:Docmost cheatsheet` | The syntax, in a floating window |
| `:Docmost diff` | Base, mine and the server's version side by side |

## Writing pages

| Want | Write |
|---|---|
| Underline | `[text]{.underline}` |
| Highlight | `[text]{.highlight color="#fef08a"}` |
| Text colour | `[text]{.textStyle color="#e03131"}` |
| Link in a new tab | `[text](https://x){target="_blank"}` |
| Math | `$x^2$`, or `$$E = mc^2$$` on its own line |
| Line break | end the line with `\` |
| Empty paragraph | a line with only `\` on it |
| Callout | `::: {.callout type="warning"}` ... `:::` |
| Collapsible section | `:::: details`, then `::: detailsSummary` and `::: detailsContent` |
| Columns | `:::: columns`, then one `::: column` each |
| Centered text | `::: {textAlign="center"}` ... `:::` |
| Image | `![caption](https://...){.image align="center"}` |

Bold, italic, code, lists, task lists and tables are plain Markdown. Mentions,
comments and attachments carry IDs only Docmost can hand out, so I copy an existing
one instead of typing it.

With LuaSnip, typing `callout`, `details`, `columns`, `highlight`, `center`, `math`,
`image`, `embed` or `mergedtable` offers a snippet to Tab through, and the usual
Markdown `table` snippets work too.

## How it works

Opening a page turns Docmost's JSON into the Markdown you see. Saving goes the other
way: Pandoc parses the buffer, the plugin turns that back into JSON and sends it.

When a page opens, its text is parsed straight back and has to give exactly the JSON
that was stored. If a block does not, it gets written in a more explicit form, and
only if that fails too does the page open read-only.

On `:w`, Pandoc parses the buffer locally and the plugin rebuilds the JSON. It reads
the page twice first, and if someone changed it in the meantime nothing is written.
The save only counts once two fresh reads return what was sent. If that never
happens the buffer stays modified, and the next `:w` checks again rather than
sending the same thing twice.

Paragraphs and headings have IDs that links point at. They never show up in the
buffer. Extmarks follow them while I edit, so rewording, adding, deleting and moving
blocks keep the right IDs.

## What is next

- **Real use on my own instance**, on a scratch page first. So far it has only run
  against the mock.
- **Creating pages and uploading images and files**, which still need the browser.
- **Editing while the browser has the page open.** That needs Docmost's live
  collaboration protocol, so for now I close the tab first.

The endpoints are internal, not a stable API. The plugin follows Docmost 0.96.0.

I write about my projects at [marc-os.com](https://marc-os.com).

## License

[AGPL-3.0](LICENSE).
