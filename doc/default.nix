{
  lib,
  pkgs,
  self,
  callPackage,
  writeText,
  stdenvNoCC,
  mdbook,
  mdbook-alerts,
  mdbook-linkcheck,
}:

let
  # Prefix to remove from option declaration file paths.
  rootPrefix = toString ../. + "/";

  # A stub pkgs used while evaluating the stylix modules for the docs
  noPkgs = {
    # Needed for type-checking
    inherit (pkgs) _type;

    # Permit access to (pkgs.formats.foo { }).type
    formats = builtins.mapAttrs (_: fmt: args: {
      inherit (fmt args) type;
    }) pkgs.formats;
  };

  # A stub config used while evaluating the stylix modules for the docs
  #
  # TODO: remove all dependency on `config` and simplify to `noConfig = null`.
  # Doing that should resolve https://github.com/nix-community/stylix/issues/98
  noConfig =
    let
      configuration = evalDocs {
        # The config.lib option, as found in NixOS and home-manager.
        # Required by the `target.nix` module.
        options.lib = lib.mkOption {
          type = lib.types.attrsOf lib.types.attrs;
          description = ''
            This option allows modules to define helper functions, constants, etc.
          '';
          default = { };
          visible = false;
        };

        # The target.nix module defines functions that are currently needed to
        # declare options
        imports = [ ../stylix/target.nix ];
      };
    in
    {
      lib.stylix = {
        inherit (configuration.config.lib.stylix)
          mkEnableIf
          mkEnableTarget
          mkEnableTargetWith
          mkEnableWallpaper
          ;
      };
    };

  evalDocs =
    module:
    lib.evalModules {
      modules = [ ./eval_compat.nix ] ++ lib.toList module;
      specialArgs = {
        pkgs = noPkgs;
        config = noConfig;
      };
    };

  # TODO: Include Nix Darwin options

  platforms = {
    home_manager = {
      name = "Home Manager";
      configuration = evalDocs [
        self.homeModules.stylix
        ./hm_compat.nix
      ];
    };
    nixos = {
      name = "NixOS";
      configuration = evalDocs self.nixosModules.stylix;
    };
  };

  metadata = callPackage ../stylix/meta.nix { };

  # We construct an index of all Stylix options, using the following format:
  #
  #     {
  #       "src/options/modules/«module».md" = {
  #         referenceSection = "Modules";
  #         readme =
  #           # Generated from modules/«module»/meta.nix
  #           ''
  #             # «name»
  #
  #             «Links to homepage(s)»
  #
  #             «Maintainers info»
  #
  #             ---
  #
  #             «Optional description»
  #           '';
  #         optionsByPlatform = {
  #           home_manager = [ ... ];
  #           nixos = [ ... ];
  #         };
  #       };
  #
  #       "src/options/platforms/«platform».md" = {
  #         referenceSection = "Platforms";
  #         readme = ''
  #           Content of doc/src/options/platforms/«platform».md, or a default
  #           title followed by a note about that file not existing.
  #         '';
  #         optionsByPlatform.«platform» = [ ... ];
  #       };
  #     }
  #
  # Options are inserted one at a time into the appropriate page, creating
  # new page entries if they don't exist.

  insert =
    {
      index,
      page,
      emptyPage,
      platform,
      option,
    }:
    index
    // {
      ${page} =
        let
          oldPage = index.${page} or emptyPage;
        in
        oldPage
        // {
          optionsByPlatform = oldPage.optionsByPlatform // {
            ${platform} = oldPage.optionsByPlatform.${platform} ++ [ option ];
          };
        };
    };

  insertDeclaration =
    {
      index,
      declaration,
      platform,
      option,
    }:
    # Only include options which are declared by a module within Stylix.
    let
      subPath = lib.removePrefix rootPrefix (toString declaration);
      pathComponents = lib.splitString "/" subPath;
    in
    # Options declared in the modules directory go to the Modules section,
    # otherwise they're assumed to be shared between modules, and go to the
    # Platforms section.
    if builtins.elemAt pathComponents 0 == "modules" then
      let
        module = builtins.elemAt pathComponents 1;
      in
      insert {
        inherit index platform option;
        page = "src/options/modules/${module}.md";
        emptyPage = {
          referenceSection = "Modules";

          readme =
            let
              maintainers =
                lib.throwIfNot (metadata ? ${module}.maintainers)
                  "stylix: ${module} is missing `meta.maintainers`"
                  metadata.${module}.maintainers;

              joinItems =
                items:
                if builtins.length items <= 2 then
                  builtins.concatStringsSep " and " items
                else
                  builtins.concatStringsSep ", " (
                    lib.dropEnd 1 items ++ [ "and ${lib.last items}" ]
                  );

              # Render a maintainer's name and a link to the best contact
              # information we have for them.
              #
              # The reasoning behind the order of preference is as follows:
              #
              # - GitHub:
              #   - May link to multiple contact methods
              #   - More likely to have up-to-date information than the
              #     maintainers list
              #   - Protects the email address from crawlers
              # - Email:
              #   - Very commonly used
              # - Matrix:
              #   - Only other contact method in the schema
              #     (as of March 2025)
              # - Name:
              #   - If no other information is available, then just show
              #     the maintainer's name without a link
              renderMaintainer =
                maintainer:
                if maintainer ? github then
                  "[${maintainer.name}](https://github.com/${maintainer.github})"
                else if maintainer ? email then
                  "[${maintainer.name}](mailto:${maintainer.email})"
                else if maintainer ? matrix then
                  "[${maintainer.name}](https://matrix.to/#/${maintainer.matrix})"
                else
                  maintainer.name;

              renderedMaintainers = joinItems (map renderMaintainer maintainers);

              ghHandles = toString (
                map (m: lib.optionalString (m ? github) "@${m.github}") maintainers
              );

              maintainersText = lib.optionalString (
                maintainers != [ ]
              ) "**Maintainers**: ${renderedMaintainers} (`${ghHandles}`)";

              # Render homepages as hyperlinks in readme
              homepage = metadata.${module}.homepage or null;

              renderedHomepages = joinItems (
                lib.mapAttrsToList (name: url: "[${name}](${url})") homepage
              );

              homepageText =
                if homepage == null then
                  ""
                else if builtins.isString homepage then
                  "**Homepage**: [${homepage}](${homepage})\n"
                else if builtins.isAttrs homepage then
                  lib.throwIf (builtins.length (builtins.attrNames homepage) == 1)
                    "stylix: ${module}: `meta.homepage.${builtins.head (builtins.attrNames homepage)}` should be simplified to `meta.homepage`"
                    "**Homepages**: ${renderedHomepages}\n"
                else
                  throw "stylix: ${module}: unexpected type for `meta.homepage`: ${builtins.typeOf homepage}";

              name = lib.throwIfNot (
                metadata ? ${module}.name
              ) "stylix: ${module} is missing `meta.name`" metadata.${module}.name;

            in
            lib.concatMapStrings (paragraph: "${paragraph}\n\n") [
              "# ${name}"
              homepageText
              maintainersText
              "---"
              metadata.${module}.description or ""
            ];

          # Module pages initialise all platforms to an empty list, so that
          # '*None provided.*' indicates platforms where the module isn't
          # available.
          optionsByPlatform = lib.mapAttrs (_: _: [ ]) platforms;
        };
      }
    else
      let
        page = "src/options/platforms/${platform}.md";
        path = ./. + "/${page}";
      in
      insert {
        inherit
          index
          platform
          page
          option
          ;
        emptyPage = {
          referenceSection = "Platforms";
          readme =
            if builtins.pathExists path then
              builtins.readFile path
            else
              ''
                # ${platform.name}
                > [!NOTE]
                > Documentation is not available for this platform. Its
                > main options are listed below, and you may find more
                > specific options in the documentation for each module.
              '';

          # Platform pages only initialise that platform, since showing other
          # platforms here would be nonsensical.
          optionsByPlatform.${platform} = [ ];
        };
      };

  insertOption =
    {
      index,
      platform,
      option,
    }:
    builtins.foldl' (
      foldIndex: declaration:
      insertDeclaration {
        index = foldIndex;
        inherit declaration platform option;
      }
    ) index option.declarations;

  insertPlatform =
    index: platform:
    lib.pipe platforms.${platform}.configuration.options [

      # Drop options that come from the module system
      (lib.flip builtins.removeAttrs [ "_module" ])

      # Get a list of all options, flattening sub-options recursively.
      # This also normalises things like `defaultText` and `visible="shallow"`.
      lib.optionAttrSetToDocList

      # Remove hidden options
      (builtins.filter (opt: opt.visible && !opt.internal))

      # Insert the options into `index`
      (builtins.foldl' (
        foldIndex: option:
        insertOption {
          index = foldIndex;
          inherit platform option;
        }
      ) index)
    ];

  index = builtins.foldl' insertPlatform { } (builtins.attrNames platforms);

  /**
    Extracts the longest markdown code fence from a string.

    - `str`: the string to be checked
    - returns: the longest sequence of "`" characters
  */
  longestFence = longestFence' "";

  longestFence' =
    prev: str:
    let
      groups = builtins.match "[^`]*(`+)(.*)" str;
      current = builtins.elemAt groups 0;
      remainingStr = builtins.elemAt groups 1;
      prevLen = builtins.stringLength prev;
      currLen = builtins.stringLength current;
      # Reduce to the longest of `prev` & `current`
      longest = if currLen > prevLen then current else prev;
    in
    # If no more matches for "`", return; otherwise keep looking
    if groups == null then prev else longestFence' longest remainingStr;

  # Renders a value, which should have been created with either lib.literalMD
  # or lib.literalExpression.
  renderValue =
    value:
    if lib.isType "literalMD" value then
      value.text
    else if lib.isType "literalExpression" value then
      let
        # If the text contains ``` characters, our code-fence must be longer
        # than the longest "```"-substring in the text.
        fence = longestFence value.text;
      in
      ''
        ${fence}```nix
        ${value.text}
        ${fence}```
      ''
    else
      throw "unexpected value type: ${builtins.typeOf value}";

  # Permalink to view a source file on GitHub. If the commit isn't known,
  # then fall back to the latest commit.
  declarationCommit = self.rev or "master";
  declarationPermalink = "https://github.com/nix-community/stylix/blob/${declarationCommit}";

  # Renders a single option declaration. Example output:
  #
  # - [modules/module1/nixos.nix](https://github.com/nix-community/stylix/blob/«commit»/modules/module1/nixos.nix)
  renderDeclaration =
    declaration:
    let
      declarationString = toString declaration;
      subPath = lib.removePrefix rootPrefix declarationString;
    in
    # NOTE: This assertion ensures all options in the docs come from stylix.
    # See https://github.com/nix-community/stylix/pull/631
    # It may be necessary to remove or relax this assertion to include options
    # with arbitrary (non-path) declaration locations.
    lib.throwIfNot (lib.hasPrefix rootPrefix declarationString)
      "declaration not in ${rootPrefix}: ${declarationString}"
      "- [${subPath}](${declarationPermalink}/${subPath})";

  # You can embed HTML inside a Markdown document, but to render further
  # Markdown between the HTML tags, it must be surrounded by blank lines:
  # see https://spec.commonmark.org/0.31.2/#html-blocks. This function
  # helps with that.
  #
  # In the following functions, we use concatStrings to build embedded HTML,
  # rather than ${} and multiline strings, because Markdown is sensitive to
  # indentation and may render indented HTML as a code block. The easiest way
  # around this is to generate all the HTML on a single line.
  markdownInHTML = markdown: "\n\n" + markdown + "\n\n";

  renderDetailsRow =
    name: value:
    lib.concatStrings [
      "<tr>"
      "<td>"
      (markdownInHTML name)
      "</td>"
      "<td>"
      (markdownInHTML value)
      "</td>"
      "</tr>"
    ];

  # Render a single option. Example output (actually HTML, but drawn here using
  # pseudo-Markdown for clarity):
  #
  #     ### stylix.option.one
  #
  #     The option's description, if present.
  #
  #     | Type    | string                                                |
  #     | Default | The default value, if provided. Usually a code block. |
  #     | Example | An example value, if provided. Usually a code block.  |
  #     | Source  | - [modules/module1/nixos.nix](https://github.com/...) |
  renderOption = option: ''
    ### ${option.name}

    ${option.description or ""}

    ${lib.concatStrings (
      [
        "<table class=\"option-details\">"
        "<colgroup>"
        "<col span=\"1\">"
        "<col span=\"1\">"
        "</colgroup>"
        "<tbody>"
      ]
      ++ (lib.optional (option ? type) (renderDetailsRow "Type" option.type))
      ++ (lib.optional (option ? default) (
        renderDetailsRow "Default" (renderValue option.default)
      ))
      ++ (lib.optional (option ? example) (
        renderDetailsRow "Example" (renderValue option.example)
      ))
      ++ (lib.optional (option ? declarations) (
        renderDetailsRow "Source" (
          lib.concatLines (map renderDeclaration option.declarations)
        )
      ))
      ++ [
        "</tbody>"
        "</table>"
      ]
    )}
  '';

  # Render the list of options for a single platform. Example output:
  #
  #     ## NixOS options
  #     ### stylix.option.one
  #     «option details»
  #     ### stylix.option.two
  #     «option details»
  renderPlatform =
    platform: options:
    let
      sortedOptions = builtins.sort (a: b: a.name < b.name) options;
      renderedOptions =
        if options == [ ] then
          "*None provided.*"
        else
          lib.concatLines (map renderOption sortedOptions);
    in
    ''
      ## ${platforms.${platform}.name} options
      ${renderedOptions}
    '';

  # Renders the list of options for all platforms on a page, preceded by the
  # module's metadata generated from modules/«module»/meta.nix.
  #
  # Example output:
  #
  #     # «name»
  #
  #     «Links to homepage(s)»
  #
  #     «Maintainers info»
  #
  #     ---
  #
  #     «Optional description»
  #
  #     ## Home Manager options
  #     *None provided.*
  #
  #     ## NixOS options
  #     «list of options»
  renderPage =
    _path: page:
    let
      options = lib.concatStrings (
        lib.mapAttrsToList renderPlatform page.optionsByPlatform
      );
    in
    lib.concatLines [
      page.readme
      options
    ];

  renderedPages = lib.mapAttrs renderPage index;

  # SUMMARY.md is generated by a similar method to the main index, using
  # the following format:
  #
  #     {
  #       Modules = [
  #         "  - [Module 1](src/options/modules/module1.md)"
  #         "  - [Module 2](src/options/modules/module2.md)"
  #       ];
  #       Platforms = [
  #         "  - [Home Manager](src/options/platforms/home_manager.md)"
  #         "  - [NixOS](src/options/platforms/nixos.md)"
  #       ];
  #     }
  #
  # Which renders to the following:
  #
  #     - [Modules]()
  #       - [Module 1](src/options/modules/module1.md)
  #       - [Module 2](src/options/modules/module2.md)
  #     - [Platforms]()
  #       - [Home Manager](src/options/platforms/home_manager.md)
  #       - [NixOS](src/options/platforms/nixos.md)
  #
  # In mdbook, an empty link denotes a draft page, which is used as a parent to
  # collapse the section in the sidebar.

  insertPageSummary =
    summary: path: page:
    let
      # Extract the title from the first line of the page, and use it in the
      # summary. This ensures that page titles match the sidebar, and ensures
      # that each page begins with a title.
      #
      # TODO: There's potential to use the title from platform pages as the
      # subheading for that platform on other pages, rather than defining a
      # name in the `platforms` attribute set earlier in this file.
      # (This is likely wasted effort unless we have a reason to add a large
      #  number of platforms.)
      text = renderedPages.${path};
      lines = lib.splitString "\n" text;
      firstLine = builtins.elemAt lines 0;
      titlePrefix = "# ";
      hasTitle = lib.hasPrefix titlePrefix firstLine;
      title = lib.removePrefix titlePrefix firstLine;
      relativePath = lib.removePrefix "src/" path;
      entry =
        if hasTitle then
          "  - [${title}](${relativePath})"
        else
          throw "page must start with a title: ${path}";
    in
    summary
    // {
      ${page.referenceSection} = (summary.${page.referenceSection} or [ ]) ++ [
        entry
      ];
    };

  summary = lib.foldlAttrs insertPageSummary { } index;

  renderSummarySection =
    referenceSection: entries:
    let
      # In mdbook, an empty link denotes a draft page, which is used as a
      # parent so the section can be collapsed in the sidebar.
      parentEntry = "- [${referenceSection}]()";
    in
    [ parentEntry ] ++ entries;

  renderedSummary = lib.concatLines (
    lib.flatten (lib.mapAttrsToList renderSummarySection summary)
  );

  # This function generates a Bash script that installs each page to the
  # correct location, over the top of an original copy of doc/src.
  #
  # Each page must be written in a separate derivation, because passing all
  # the text into a single derivation exceeds the maximum size of command
  # line arguments.
  #
  # TODO: It should be possible to use symlinkJoin here, which would make the
  # code more robust at the expense of another intermediate derivation.
  # However, that derivation would be useful during development for inspecting
  # the Markdown before it's rendered to HTML.
  writePages = lib.concatLines (
    lib.mapAttrsToList (
      path: text:
      let
        file = writeText path text;
      in
      "install -D ${file} ${path}"
    ) renderedPages
  );

  # Every option has a separate table containing its details. This CSS makes
  # the following changes for better consistency and compactness:
  #
  # - Fix the width of tables and their columns, so the layout is consistent
  #   when scanning through the options. By default, tables are centered and
  #   sized to their individual content.
  # - Remove the alternating background colour from rows, which is distracting
  #   when there is a small number of rows with a potentially large amount
  #   of text per row.
  # - Allow text within a cell to scroll horizontally, which is useful for
  #   wide code blocks, especially on mobile devices.
  # - Remove bullet points from lists; this is intended for the list of
  #   declarations, as it often contains only one item. Again, this is aimed
  #   at mobile devices where horizontal space is limited.
  #   TODO: Constrain this rule to only apply to the declarations list, as it
  #   may interfere with option descriptions that contain lists.
  extraCSS = ''
    .option-details {
      width: 100%;
      table-layout: fixed;
    }
    .option-details col:first-child {
      width: 7.5em;
    }
    .option-details col:last-child {
      width: 100%;
      overflow-x: auto;
    }
    .option-details tr {
      background: inherit !important;
    }
    .option-details ol, .option-details ul {
      list-style: none;
      padding: unset;
    }
  '';

in
stdenvNoCC.mkDerivation {
  name = "stylix-book";
  src = ./.;
  buildInputs = [
    mdbook
    mdbook-alerts
    mdbook-linkcheck
  ];

  inherit extraCSS renderedSummary;
  passAsFile = [
    "extraCSS"
    "renderedSummary"
  ];

  patchPhase = ''
    ${writePages}
    cat $renderedSummaryPath >>src/SUMMARY.md
    cp ${../README.md} src/README.md
    cp ${../gnome.png} src/gnome.png
    cp ${../kde.png} src/kde.png
  '';

  buildPhase = ''
    runHook preBuild
    mdbook build
    runHook postBuild
  '';

  postBuild = ''
    cp --recursive book/html $out
    cat $extraCSSPath >>$out/css/general.css
  '';
}
