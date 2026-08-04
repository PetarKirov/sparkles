# A visual stress fixture for nvim-treesitter-style language injections.
#
# The deepest branch is:
#
#   Nix -> Bash -> Haskell -> HTML -> JavaScript -> HTML -> JavaScript
#       -> HTML -> CSS
#
# Each boundary is selected by an injections.scm query: the adjacent language
# comment selects Bash, Bash uses the heredoc terminator as the language name,
# Markdown uses the fence info string, Haskell recognizes quasiquoters, HTML
# recognizes script/style elements, and JavaScript recognizes tagged templates.
{
  script = /* bash */ ''
        set -eu

        work=polyglot-fixture
        mkdir -p "$work"

        # The deepest branch reaches the highlighter's depth cap:
        # Nix -> Bash -> Haskell -> HTML -> JavaScript -> HTML -> JavaScript
        #     -> HTML -> CSS.
        cat > "$work/direct.hs" <<'HASKELL'
          {-# LANGUAGE OverloadedStrings #-}
          {-# LANGUAGE QuasiQuotes #-}

          module Main where

          import Text.Blaze.Html (Html)
          import Text.Hamlet (shamlet)

          page :: Html
          page = [shamlet|
            <main class=direct>
              <h1>Direct Haskell heredoc
              </h1>
              <script>
                const card = html`
                  <button onclick="document.head.innerHTML =
                    '<style>.direct { color: rebeccapurple; }</style>'">
                    Paint the page
                  </button>
                `;
                document.body.append(card.content.cloneNode(true));
              </script>
            </main>
          |]

          main :: IO ()
          main = pure ()
        HASKELL

        # Another dynamic heredoc language. The body deliberately contains a
        # fenced Haskell sample, making this useful when inspecting how source
        # indentation and included ranges interact in the Markdown scanner.
        cat > "$work/deep.md" <<'MARKDOWN'
    # An eight-language document

    The outer heredoc is Markdown. Its fenced block switches to Haskell.

    ```haskell
    {-# LANGUAGE QuasiQuotes #-}

    import Text.Blaze.Html (Html)
    import Text.Hamlet (hamlet)

    dashboard :: Html
    dashboard = [hamlet|
      <section class=dashboard>
        <h2>Language layers</h2>
        <script>
          const theme = html`
            <style>
              .dashboard {
                display: grid;
                color: oklch(72% 0.18 292);
              }
            </style>
          `;
          document.head.append(theme.content.cloneNode(true));
        </script>
      </section>
    |]
    ```
        MARKDOWN

        # A separate deep branch through C++ raw-string delimiter injection:
        # Nix -> Bash -> C++ -> HTML -> JavaScript -> HTML -> CSS.
        cat > "$work/raw-string.cpp" <<'CPP'
          #include <string_view>

          constexpr std::string_view page = R"html(
            <article class="cpp-card">
              <h2>C++ raw string</h2>
              <script>
                const styles = html`<style>.cpp-card { border: 2px solid teal; }</style>`;
                document.head.append(styles.content.cloneNode(true));
              </script>
            </article>
          )html";
        CPP

        # Breadth cases: Bash's generic heredoc rule should select each grammar
        # from the terminator, independently of the deeper examples above.
        cat > "$work/data.json" <<'JSON'
          {
            "fixture": "nested-injections",
            "layers": 8,
            "enabled": true
          }
        JSON

        cat > "$work/settings.toml" <<'TOML'
          title = "Nested injections"
          depth = 8
          languages = ["nix", "bash", "haskell", "html", "javascript", "css"]
        TOML

        cat > "$work/workflow.yaml" <<'YAML'
          fixture:
            name: nested-injections
            checks:
              - heredoc-language
              - recursive-layering
        YAML

        cat > "$work/check.py" <<'PYTHON'
          from pathlib import Path

          files = sorted(Path("polyglot-fixture").iterdir())
          print(f"generated {len(files)} polyglot files")
        PYTHON
  '';
}
