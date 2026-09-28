# docmost.nvim

Browse and search a Docmost Community workspace, open **every** page as Markdown,
and save it with `:write`. Uses ordinary user sessions and the application's
internal endpoints. No enterprise API key, Node helper, or Neovim UI dependency.

**Status:** implemented and tested against local HTTP/HTTPS mocks. Authenticated
reads and writes against `https://docs.example.com` have **not** been verified, and
its installed version is unknown. Do the disposable-page check below before
editing real documents. The source contract is pinned to Docmost **0.96.0**, commit
`7bef7b1a00d31991f009865ec14c8d06540eb1f0`; this is not a supported-version claim.
The endpoint contracts follow the [pinned upstream source](https://github.com/docmost/docmost/tree/7bef7b1a00d31991f009865ec14c8d06540eb1f0).

Docmost stores pages as structured JSON documents, not Markdown, and its own Markdown
export drops attachments, mentions, comment anchors, colours, alignment and more.
So this plugin brings its own lossless dialect: plain Markdown wherever Markdown can
say it, and Pandoc's attribute syntax (`{...}`, `:::` blocks, `[text]{.class}`) for
everything else. Every node and attribute has a text form, so pages with tables,
images, callouts, mentions or blocks the plugin has never seen all open editable.
Pandoc (installed here) converts your edits back to JSON locally.

## Installation: NvChad / lazy.nvim

Requires Neovim **0.10+**, `curl`, and **Pandoc** (without it, pages open read-only).
Tested with Neovim **0.12.5** and Pandoc **3.10.2**. LuaSnip is optional, for snippets.
Add this entry to the table returned by `~/.config/nvim/lua/plugins/init.lua`:

```lua
{
  'mmrmagno/docmost.nvim',
  cmd = 'Docmost',
  opts = {
    base_url = 'https://docs.example.com',
    persist_session = true, -- stay signed in across restarts; see below
  },
},
```

[examples/nvchad.lua](examples/nvchad.lua) contains a complete returned spec table.
For a local checkout, use `dir = '/path/to/docmost.nvim'` instead of the repo name.
Ordinary Neovim can add this directory to `runtimepath` and call:

```lua
require('docmost').setup({ base_url = 'https://docs.example.com' })
```

The URL is the origin, without `/api` or another path. Production requires HTTPS.
Curl validates TLS certificates normally. No redirects are followed, and the plugin
disables `.curlrc` loading. `allow_insecure_localhost` is exclusively for explicitly
enabled `http://127.0.0.1:<port>` test servers; it does not disable TLS validation.
Custom trusted CAs can be supplied through curl's `CURL_CA_BUNDLE`.

## Authentication, locally

Run `:Docmost login`. Enter your email and password in **Neovim**, not in chat or
your configuration. The password uses Neovim's secret prompt. The plugin captures
the `authToken` login cookie and validates it with `/users/me`. Credentials and
cookies travel to curl over stdin, never in process arguments, shell commands,
notifications, or logs. The password is not persisted.

Sessions are memory-only by default. Set `persist_session = true` to retain an
origin-bound session in Neovim's state directory. Directories use mode `0700` and
files use `0600`. Backups and sessions are private plaintext, not encrypted.
`:Docmost logout` cancels active requests, forgets the local token, and removes the
plugin-managed session file. It does not revoke your browser session or delete an
externally supplied token/file. A 401 blocks reuse until login or a Neovim restart.

SSO/MFA flows are not implemented. You can supply your own normal browser session
locally: use the `authToken` cookie for this exact origin, never pasted into chat.
One memory-only configuration option is:

```lua
session_token = function() return vim.env.DOCMOST_SESSION_TOKEN end,
```

In **zsh**, prompt without putting the value into history or process arguments:

```zsh
read -rs 'DOCMOST_SESSION_TOKEN?Docmost authToken: '
echo
export DOCMOST_SESSION_TOKEN
nvim
unset DOCMOST_SESSION_TOKEN
```

Alternatively set `session_file = '/absolute/private/session.json'`. The file must
be mode `0600`, contain `{"base_url":"https://docs.example.com","token":"..."}`,
and live in a private directory outside your repository. Files for another origin
are ignored. A `session_token` provider takes precedence over session files.
`:Docmost status` validates the session without printing tokens or account details.

## Use

### The workspace

Run `:Docmost`. A floating workspace opens over the editor: a tree of your spaces
and pages on the left and a read-only preview of the selected page on the right.
It uses your colour scheme (NvChad's base46 themes included) and needs no icon
font or extra plugin. Press `?` at any time for the full key list.

```
╭ docmost  docs.example.com  ● signed in ─╮╭ Engineering › Runbooks › Backups ─────╮
│ OPEN PAGES                              ││ Backups                               │
│ ● Weekly notes                  unsaved ││                                       │
│                                         ││ ● Editable in Neovim                  │
│ SPACES                                  ││ Close the browser editor for this     │
│ ▾ Engineering                           ││ page before saving here.              │
│   ▾ Runbooks                            ││ ───────────────────────────────────── │
│     · Backups                           ││ # Backups                             │
│     + Load more                         ││ ...                                   │
│ ▸ Personal                              ││                                       │
╰ ⏎ open  l/h tree  / search  p preview  ─╯╰─────────────────── read-only preview ╯
```

- **Signing in.** Signed out, the tree shows a short card. Press `a`, type your
  email, then your password in Neovim's secret prompt. Spaces load as soon as the
  session is valid. The title shows `signed in`, `session expired` or `signed out`;
  an expired session adds a banner and your open pages keep their edits.
- **Browsing.** `l` expands a space or page and fetches its children only then,
  `h` collapses or jumps to the parent, `-` collapses back to the space. Each level
  has its own **Load more** row. Errors appear under the node that failed; `r`
  retries it.
- **Opening.** Enter opens the page as a normal Markdown buffer in the window you
  came from; `Ctrl-v`, `Ctrl-x` and `Ctrl-t` open it in a vertical split,
  horizontal split or new tab. The workspace closes, and `:Docmost` brings it back
  exactly where you left it: same expanded nodes, selection and scroll.
- **Open pages.** Pages you have open appear at the top with their state
  (`unsaved`, `saving`, `verified 14:05`, `conflict`, `uncertain`, `read-only`).
  `w` saves and verifies the selected open page (or the page you came from), `R`
  reloads a clean page, `d` opens the base/local/remote diff.
- **Search.** `/` opens a query line above the tree. Results update as you type,
  after a short pause; an older request is cancelled and a late reply is ignored.
  Enter or Down moves to the results, `/` edits the query again, Esc returns to the
  tree with your previous selection, and `Ctrl-c` clears the search from the query.
- **Preview.** Moving onto a page shows its title, whether it is editable (or why
  not, in plain language), the state of its open buffer and the page body. It is a
  separate scratch buffer, never your page buffer, and results are cached for the
  session. `p` hides it. On narrow screens the list takes the full width and `p`
  swaps to the preview and back. `ui.preview = false` stops remote preview reads.
- **Actions.** `.` lists everything available for the selected row: open variants,
  child pages, refresh, copy page ID, save, reload and diff.
- **Focus.** `q` or Esc closes the workspace. Moving to another editor window
  closes it too; Neovim's own prompts and pickers do not.

| Key | Action |
| --- | --- |
| `j` / `k`, arrows, `gg` / `G` | Move between rows |
| Enter | Open page, expand or collapse space, run the selected action |
| `l` / `h` / `-` | Expand children / collapse or go to parent / collapse to the space |
| `Ctrl-v` / `Ctrl-x` / `Ctrl-t` | Open in vertical split / horizontal split / tab |
| `/` | Search (Esc from results returns to the tree) |
| `p` | Show or hide the preview (swap on narrow screens) |
| `r` | Refresh or retry the selected row |
| `.` | Actions for the selected row |
| `o` | Open a page by URL or ID |
| `a` / `L` | Sign in with a secret prompt / sign out locally |
| `w` / `R` / `d` | Save and verify / safe reload / diff for an open page |
| `?` / `q` | Help / close |

In NvChad you can bind the workspace to a key in `lua/mappings.lua`:

```lua
vim.keymap.set('n', '<leader>dm', '<cmd>Docmost<cr>', { desc = 'Docmost workspace' })
```

### Editing pages

Pages are ordinary Markdown buffers: normal motions, undo and `:write` all work.
The window's winbar shows the page title, whether it is editable, the save state
and a one-line hint, for example `docmost  Backups · editable · verifying    Reading
back until two fresh reads match`. `b:docmost_status` holds the raw state for your
own statusline. `ui.winbar = false` turns the winbar off; a winbar you set yourself
is never replaced.

| State | Meaning |
| --- | --- |
| `unsaved` | Local edits. `:w` saves and verifies. |
| `checking`, `preparing`, `saving`, `verifying` | A save is running. Keep editing if you like; new edits stay unsaved. |
| `verified 14:05` | Two fresh reads matched what you wrote. |
| `conflict` | The page changed on the server. Nothing was written. `:Docmost diff`, then reload and merge. |
| `uncertain` | The server did not confirm the save. `:w` checks again by reading and never resends. |
| `rejected`, `not saved`, `blocked` | Nothing was persisted. The hint explains why; edits are kept. |
| `read-only` | Your account cannot edit the page, Pandoc is missing, or (a bug) the page could not be reproduced exactly. |

### The page format

Each page starts with its title (and icon, if it has one). Change it and `:w` to
rename the page; the rename is sent separately, after the body, and verified the
same way. Delete the header if you never want to rename from here.

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

![Architecture](/files/diagram.png){.image width="600" attachmentId="a1"}

[notes.pdf](/files/notes.pdf){.attachment size="2048" attachmentId="a2"}

::: {textAlign="center"}
Centered text
:::
```

| Docmost content | In the buffer |
| --- | --- |
| Headings, paragraphs, lists, quotes, code, rules, bold, italic, strike, code | Plain Markdown |
| Task lists | `- [ ]` and `- [x]` |
| Links (with target etc.) | `[text](url){target="_blank"}` |
| Hard line break | `\` at the end of a line |
| Empty paragraph | a line holding only `\` |
| Underline, highlight, colour, sub/superscript, comment anchors | `[text]{.underline}`, `[text]{.highlight color="#ff0"}`, `[text]{.comment commentId="…"}` |
| Mentions | `[@Name]{.mention x-id="…" entityType="user"}` |
| Math | `$x^2$` inline, `$$\int x$$` on its own line |
| Simple tables | Pipe tables |
| Tables with merged cells or widths | `::: table` / `:::: tableRow` / `::: {.tableCell colspan="2"}` blocks |
| Images, video, audio, PDF, drawings | `![caption](src){.image …}` (class names the kind) |
| Attachments | `[name](url){.attachment …}` |
| Callouts, details, columns, embeds, page breaks, synced blocks, anything new | `::: {.callout type="info"}` … `:::`, named after the Docmost block |
| Alignment, indentation | a `::: {textAlign="center"}` block around the paragraph |

Attribute values are written as they are stored; `j:` values are encoded JSON and
`x-id` is Docmost's own `id` attribute. Block IDs of paragraphs and headings never
appear: the plugin tracks them with extmarks as you edit, so text changes, new
blocks, deleted blocks and moved blocks all keep the right IDs in one save. The
`{...}` parts are concealed except on the cursor line, and media lines get a small
label. `:Docmost inspect` shows the construct under the cursor; `:Docmost check`
validates the whole buffer and marks problems as diagnostics without sending
anything. Completion (`<C-x><C-o>`) offers block and style names after `{.` and
known attribute names after a class.

### Cheatsheet

Also inside Neovim with `:Docmost cheatsheet`.

| Want | Type |
| --- | --- |
| Rename the page | edit `title:` in the header at the top |
| Bold, italic, strike, code | `**bold**` `*italic*` `~~strike~~` `` `code` `` |
| Link, opening in a new tab | `[text](https://x)` `[text](https://x){target="_blank"}` |
| Underline | `[text]{.underline}` |
| Highlight | `[text]{.highlight color="#fef08a"}` |
| Text colour | `[text]{.textStyle color="#e03131"}` |
| Sub and superscript | `H~2~O` `x^2^` |
| Math | `$x^2$` inline, `$$E = mc^2$$` alone on a line |
| Line break inside a paragraph | end the line with `\` |
| Empty paragraph | a line holding only `\` |
| Task list | `- [ ] todo` `- [x] done` |
| Table | a normal pipe table |
| Callout | `::: {.callout type="warning"}` text `:::` |
| Collapsible section | `:::: details` then `::: detailsSummary` and `::: detailsContent` |
| Columns | `:::: columns` then one `::: column` per column |
| Centered or right aligned | `::: {textAlign="center"}` paragraph `:::` |
| Image from a URL | `![caption](https://…){.image align="center"}` |
| Embed | `::: {.embed provider="youtube" src="https://…"}` `:::` |
| Mention, comment, attachment | copy an existing one: their IDs come from Docmost |

Blocks with `:::` fences can hold any other blocks, so a callout can contain a
list or a table. Use more colons on the outer fence when nesting (`::::` around
`:::`), it keeps them readable.

### Snippets

With LuaSnip (NvChad ships it, together with blink.cmp), page buffers get snippets
for the syntax above. Type the name, accept it from the completion menu, then
Tab through the fields. They only appear in Docmost buffers.

| Snippet | Inserts |
| --- | --- |
| `callout` | a callout, with the type as a choice |
| `details` | a collapsible section |
| `columns` | two columns |
| `task` | a task item |
| `highlight`, `underline`, `color` | styled text |
| `math`, `mathblock` | inline or block math |
| `center` | an aligned paragraph |
| `newtab` | a link opening in a new tab |
| `image`, `embed` | an image or an embed from a URL |
| `mergedtable` | a table with a merged header cell |

friendly-snippets' Markdown `table` snippets work too; pipe tables are valid pages.

Tips (also in `:Docmost guide`):

- Add a block by writing it, separated by blank lines. Copy an existing `:::` block
  to make another one of the same kind.
- New images and attachments need an uploaded file; move, delete or re-caption the
  existing ones, and upload new ones in the browser for now.
- Typing two spaces in Markdown gives one; existing multiple spaces are kept.
- A `#` heading changes the body; the `title:` line renames the page. Creating
  pages is not implemented yet.
- Close the browser editor for a page before editing it here, and try a disposable
  page first.

| Command | Behavior |
| --- | --- |
| `:Docmost` / `:Docmost ui` | Open the workspace, or return to it |
| `:Docmost guide` | Editing tips in a small floating window |
| `:Docmost check` | Validate the buffer and show problems as diagnostics; sends nothing |
| `:Docmost inspect` | Show the block or style under the cursor with its attributes |
| `:Docmost cheatsheet` | The syntax for every kind of block, in a floating window |
| `:Docmost login` / `logout` | Local session login/logout |
| `:Docmost spaces` | Choose a space, root page, then open it or browse its children |
| `:Docmost search [query]` | Search, prompting if no query was provided |
| `:Docmost open <id-or-url>` | Open a UUID, slug ID, or URL from the configured origin |
| `:write` / `:Docmost save` | Save asynchronously and verify, or reconcile an uncertain save |
| `:Docmost reload` | Re-read a clean buffer; refuse to discard edits or pending outcomes |
| `:Docmost! reload` | Explicitly replace local edits with remote content, after a private backup |
| `:Docmost diff` | Open base/local/remote Markdown in three diff panes |
| `:Docmost cancel` | Cancel the current buffer operation; an update already sent remains uncertain |
| `:Docmost status` | Validate authentication and show compatibility/current-page state |
| `:Docmost version` | Query the optional deployment version endpoint |
| `:checkhealth docmost` | Check local requirements/configuration, with no remote mutations |

The explicit `spaces` and `search` commands also provide compact pickers using
`vim.ui.select`/`vim.ui.input`, including NvChad's configured provider.
Choose **Load more…** for another batch. Spaces and sidebar pages use cursors;
search uses offsets. Children are fetched only when requested. Search may offer
one final empty batch because the endpoint supplies no total count.

Buffers are named `docmost://<host>/<page-id>`, use `filetype=markdown` and
`buftype=acwrite`, and remain available when hidden. UUIDs and URL aliases resolve
to one buffer. The first heading does not rename a page; the `title:` line does. Wait for **Save verified by repeated read-back** before quitting.
`:write` returns immediately; `:wq` is not an asynchronous save-and-quit operation.
Use a separate ordinary buffer if you want a local Markdown export.

## Save behavior and recovery

1. Unchanged content is a no-op, including a different Markdown spelling of the
   same content (`_x_` for `*x*`). Such saves never rewrite your buffer.
2. The buffer is parsed locally with Pandoc and rebuilt into Docmost JSON. Unknown
   styles or blocks, broken structure and malformed attributes are reported as
   diagnostics and nothing is sent.
3. Before sending an update, create a private recovery record with raw JSON, the
   page text, metadata, and your edit snapshot. Backup failure blocks the update.
4. Read the page twice. Reject inconsistent reads and compare content and metadata
   with the opening baseline. Remote changes block the save; `:Docmost diff` shows
   all three versions.
5. Replace content on the **same page ID** with `format: "json"`. A title or icon
   change follows as its own update once the body is verified.
6. Poll fresh reads until the stored document matches what was sent in at least
   two consecutive stable reads: same structure, text and styles, and every
   attribute that was sent, including block IDs. The server may add IDs and
   defaults to new blocks and a trailing empty paragraph. The default window is 60
   seconds to allow collaboration persistence delays. HTTP 200 alone never counts.
7. Clear `modified` only if changedtick and content still match the submitted
   snapshot. New edits remain untouched and modified.

Opening a page runs the reverse check first: the page text must convert back to
exactly the stored JSON. When the readable form of a block cannot, that block is
written in a more explicit form instead (for example `[x]{.bold}` rather than
`**x**`). Only if even that fails does the page open read-only, naming the block.

Timeouts and ambiguous update failures retain the submitted snapshot. Repeating
`:write` then **only reads to reconcile**, never resends the update. If repeated
reads still show the old body, new writes are blocked for this Neovim session with
an HTTP compatibility message. There is no delete/recreate fallback.

For a conflict, copy the desired changes from the LOCAL diff, return to the page
buffer, run `:Docmost! reload`, and merge onto the new baseline. For an uncertain
write, reconcile first and wait until server persistence settles before explicitly
reloading; an old delayed write can still arrive later. Reload also refuses to
discard edits entered while its request was pending.

Recovery records are under `stdpath('state')/docmost/backups/<instance-page-hash>/`,
retaining 20 records per page by default. Each includes `local_markdown`, `baseline`,
and any `pending` snapshot. After a restart, open a selected backup JSON file, then
open its local Markdown in a separate scratch buffer with this command (no remote
save is performed):

```vim
:lua local d=vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false), '\n')); vim.cmd('new'); vim.bo.buftype='nofile'; vim.bo.swapfile=false; vim.bo.undofile=false; vim.bo.filetype='markdown'; vim.api.nvim_buf_set_lines(0,0,-1,false,vim.split(d.local_markdown,'\n',{plain=true}))
```

Modified buffers also get backups on unload and normal exit. Reopening a closed
page in the same process restores retained edits. Swap and persistent undo files
are disabled for remote buffers. This is not a continuous crash-recovery journal:
edits since the last backup can be lost in a process/OS crash. An update already
sent can complete after cancellation or quitting; inspect remote state on reopening.

## Fidelity and concurrency limits

The format is tested with golden examples of every construct above, randomly
generated documents full of Markdown-significant characters, and edits through a
real buffer. It has not yet been run against real pages from the deployed server;
node types and attributes follow the pinned upstream schema. Unknown future blocks
still round-trip in the generic `:::` form. Uploading new images and attachments
and choosing new mentions still need the browser.

Use **one active editor per page**. Close the web editor and allow its changes to
persist before opening a page in Neovim. Pre-save comparison is not atomic: browser
changes can remain unpersisted or arrive between comparison and replacement. The
internal update DTO has no known expected-revision field. Repeated read-back is
evidence of persisted endpoint state, not a storage-durability guarantee or live
collaboration protocol. Simultaneous browser editing is not safe.

Page creation/deletion, uploads, multi-instance sessions, SSO/MFA flows, and live
Yjs collaboration are not implemented. No minimum compatible Docmost release
is established. Older releases may accept an update without changing its body.

## Configuration defaults

```lua
require('docmost').setup({
  base_url = 'https://docs.example.com',
  timeout_ms = 15000,
  max_response_bytes = 8 * 1024 * 1024,
  verify_timeout_ms = 60000,
  verify_interval_ms = 2000,
  verify_reads = 2, -- at least two
  page_size = 50, -- 1..100
  max_pages = 100, -- per picker traversal
  backup_retention = 20, -- per page, at least one
  state_dir = vim.fn.stdpath('state') .. '/docmost',
  persist_session = false,
  edit_title = true, -- title/icon header at the top of each page
  ui = {
    width = 0.9, -- fraction of the screen, or cells
    height = 0.86,
    border = 'rounded', -- none, single, double, rounded, solid, shadow
    icons = 'unicode', -- plain geometric characters; 'ascii' for any font
    preview = true, -- false: no remote reads for the preview pane
    winbar = true, -- page state in page windows
    conceal = true, -- hide {...} attribute parts off the cursor line
    search_debounce_ms = 250,
    preview_debounce_ms = 150,
  },
  -- session_token = function() return vim.env.DOCMOST_SESSION_TOKEN end,
  -- session_file = '/absolute/private/session.json',
})
```

Restart Neovim to change configuration with pages open. Keep state outside the
repository. Backups can contain private page content.
Workspace width/height accept screen fractions up to 1 or integer cell counts. It is
clamped to the screen and re-laid out on resize: two panes from about 107 columns,
one pane below that, and a compact single pane on very small screens.
Highlight groups start with `Docmost` (for example `DocmostBrand`,
`DocmostSelection`, `DocmostSection`) and link to standard groups, so any colour
scheme styles them; override them after your colour scheme loads.

## Tests and live verification

Validation on 2026-09-28: **235 HTTP/HTTPS integration assertions, 230 page-format
assertions (golden examples, 60 random documents, buffer edits and every snippet,
with real Pandoc), 29 layout assertions and 166 workspace assertions passed** on
Neovim 0.12.5. The example spec loaded through an installed lazy.nvim, and the
snippets were checked in NvChad's blink.cmp menu. Rich pages were inspected
rendered in a real terminal. StyLua checks passed. No production compatibility is
claimed.

Run the loopback-only suite (Neovim, curl, Pandoc, Python 3.9+, and OpenSSL CLI required):

```sh
cd docmost.nvim
python3 tests/run.py
```

It starts temporary HTTP/HTTPS servers, uses random synthetic credentials, and
writes state/certificates into an automatically removed temporary directory. It
never reads your real session or contacts production. It tests TLS validation,
cookie login, pagination/navigation, redacted errors, consistent reads, replacement
and reopen, delayed/ignored updates, empty/null bodies, conflicts, read-only gates,
changedtick behavior, cancellation, closed buffers, timeouts, and session expiry.
Workspace checks cover window ownership and focus, secret prompts, per-node
pagination and on-demand children, restored selection and scroll, debounced and
cancelled search with stale replies ignored, cached and stale-safe previews,
wide/narrow/tiny layouts, expired sessions, winbar and badge states through a
verified save, plain-language restrictions, and edits kept through logout and
failures.
The mock is **not a full Markdown/Yjs implementation**.

To also exercise the example using an already installed lazy.nvim (no downloads),
set `DOCMOST_TEST_LAZY_PATH` to its checkout directory when running the suite. Set
`DOCMOST_TEST_LUASNIP_PATH` to a LuaSnip checkout to check that every snippet
expands to a valid page.
All Neovim config/data/state/cache paths used by the tests are temporary.

Optional live smoke check:

1. Configure and authenticate **locally** as above. Run `:Docmost status` and
   `:Docmost version`; if version lookup fails, inspect your deployment image tag
   or UI. Record the version without sharing tokens or passwords.
2. Designate a disposable page by URL/ID, created manually in the browser if needed.
   Close its browser editor, wait for persistence, and open **only that page** with
   `:Docmost open <url>`. Do not test writes on normal documents.
3. If read-only, record the displayed reason and stop the write check. Do not
   force-enable writes.
4. Otherwise replace its body with a unique plain marker such as
   `docmost.nvim smoke 2026-09-28 <your-random-suffix>` and `:write`. Record verification
   result and elapsed time. Reload, close/reopen the Neovim page, and confirm the
   same page ID and marker in a fresh browser view.
5. In the browser, add rich content to the same page (a table with merged cells,
   an image, an attachment, a callout, a mention, a comment, centered text). Close
   the browser editor, reopen in Neovim, change one sentence, `:w`, then check in a
   fresh browser view that everything else is untouched and comments still anchor.
6. Change the `title:` line, `:w`, and confirm the rename in the browser.
7. Clear the buffer body and `:write` again. Verify emptiness after reopening.
8. Record version, disposable page identity, timing, marker/empty-body outcomes,
   and any read-only reason. No other pages need modification. Inspect any failed
   or uncertain outcome before retrying or restoring content.

No authenticated live smoke test has been performed during this implementation.
