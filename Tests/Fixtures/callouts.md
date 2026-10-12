# Callout corpus

Fixture for GitHub-style callouts (DW-006), shared by the Core tests (`CalloutTests`), the editor tests, the real-app step and the `gh api markdown` cross-check. Every `##` heading is one row: `## <id> <expected>`, then the Markdown under test up to the next heading. `<expected>` is `plain` (not a callout), `callout <kind>`, or `callout <kind> "<title>"`. Two spec rows cannot sit in a shared document, because a reference definition (`[!note]: https://x`, or `[!NOTE]: x` in a quote) turns every marker in the file into a link; they are literals in `CalloutTests`.

## note-upper callout note

> [!NOTE]
> body

## note-lower callout note

> [!note]
> body

## note-mixed callout note

> [!Note]
> body

## tip callout tip

> [!TIP]
> body

## important callout important

> [!IMPORTANT]
> body

## warning callout warning

> [!WARNING]
> body

## warning-mixed callout warning

> [!wArNiNg]
> body

## caution callout caution

> [!CAUTION]
> body

## no-space callout note

>[!NOTE]
>body

## two-spaces callout note

>  [!NOTE]
> body

## four-spaces callout note

>    [!NOTE]
> body

## five-spaces plain

>     [!NOTE]
> body

## tab-after-quote callout note

>	[!NOTE]
>	body

## indent-three callout note

   > [!NOTE]
   > body

## trailing-spaces callout note

> [!NOTE]  
> body

## trailing-tab callout note

> [!NOTE]	
> body

## blank-line callout note

> [!NOTE]
>
> body

## lazy callout note

> [!NOTE]
body

## list callout note

> [!NOTE]
> - one
> - two

## fence callout note

> [!NOTE]
> ```
> code
> ```

## heading-body callout note

> [!NOTE]
> # Heading

## second-marker callout note

> [!NOTE]
> [!TIP]
> body

## blank-first callout note

>
> [!NOTE]
> body

## after-quote callout note

> plain quote

> [!NOTE]
> body

## table callout note

> [!NOTE]
> | a | b |
> |---|---|
> | 1 | 2 |

## table-after-text callout note

> [!NOTE]
> intro
> | a | b |
> |---|---|
> | 1 | 2 |

## table-blank-first callout note

>
> [!NOTE]
> | a | b |
> |---|---|
> | 1 | 2 |

## title callout note "My title"

> [!NOTE] My title
> body

## title-only callout warning "Data loss"

> [!WARNING] Data loss

## title-tab callout tip "Tab title"

> [!TIP]	Tab title
> body

## title-trailing callout note "My title"

> [!NOTE] My title   
> body

## title-inline callout important "**Bold** and `code`"

> [!IMPORTANT] **Bold** and `code`
> body

## title-link callout note "See [docs](https://example.com)"

> [!NOTE] See [docs](https://example.com)
> body

## title-marker callout caution "Use [!TIP] here"

> [!CAUTION] Use [!TIP] here
> body

## title-unicode callout note "Héllo 😀 wörld"

> [!NOTE] Héllo 😀 wörld
> body

## title-table callout note "with a title"

> [!NOTE] with a title
> | a | b |
> |---|---|

## alone plain

> [!NOTE]

## alone-empty-lines plain

> [!NOTE]
>
>

## alone-trailing-spaces plain

> [!NOTE]   

## alone-blank-text plain

> [!NOTE]
>   

## unknown plain

> [!INFO]
> body

## plus plain

> [!NOTE]+
> body

## minus plain

> [!NOTE]-
> body

## space-inside plain

> [! NOTE]
> body

## no-bang plain

> [NOTE]
> body

## unclosed plain

> [!NOTE
> body

## glued plain

> [!NOTE]x
> body

## bold plain

> **[!NOTE]**
> body

## text-first plain

> hello
> [!NOTE]
> body

## after-paragraph plain

> intro
>
> [!NOTE]
> body

## in-list plain

- item
  > [!NOTE]
  > body

## nested plain

> > [!NOTE]
> > body

## backslash plain

> [!NOTE]\
> body

## setext plain

> [!NOTE]
> ---
