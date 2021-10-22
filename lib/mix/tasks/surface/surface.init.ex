defmodule Mix.Tasks.Surface.Init do
  @moduledoc """
  Configures Surface on an phoenix project.

  This task is mostly meant to be used after bootstrapping a fresh Phoenix project using
  `mix phx.new`. Although it can also be used on existing non-fresh projects, some patches
  might not be applicable as they may depend on file content code/patterns that are no longer available.

  If such cases are detected, the task will inform which patches were skipped as well as provide
  instructions for manual configuration.

      $ mix surface.init

  ## Important note

  This task is still **experimental**. Make sure you have committed your work or have a proper
  backup before running it. As it may change a few files in the project, it's recommended to
  have a safe way to rollback the changes in case anything goes wrong.

  ## Options

    * `--catalogue` - Configures the experimental Surface Catalogue for the project, which
      will be available at the `/catalogue` route. For more information
      see: https://github.com/surface-ui/surface_catalogue.

    * `--demo` - Generates a sample `<Hero>` component. When used together with the `--catalogue`
      option, it additionally generates two catalogue examples and a playground for the component.

    * `--yes` - automatic answer "yes" to all prompts. Warning: this will also say "yes"
      to overwrite existing files as well as fetching/installing dependencies, if required.

    * `--no-formatter` - do not configure the Surface formatter.

    * `--no-js-hooks` - do not configure automatic loading of colocated JS hook files.

    * `--no-error-tag` - do not configure the `ErrorTag` component to use
      the `ErrorHelpers.translate_error/1` function generated by `mix phx.new` when Gettext
      support is detected.

    * `--no-dep-install` - do not fetch and install added dependencies.

  """

  use Mix.Task

  alias Mix.Tasks.Surface.Init.Patcher
  alias Mix.Tasks.Surface.Init.ExPatcher
  alias Mix.Tasks.Surface.Init.Patches

  @switches [
    formatter: :boolean,
    catalogue: :boolean,
    demo: :boolean,
    yes: :boolean,
    js_hooks: :boolean,
    error_tag: :boolean,
    dep_install: :boolean
  ]

  @default_opts [
    formatter: true,
    catalogue: false,
    demo: false,
    yes: false,
    js_hooks: true,
    error_tag: true,
    dep_install: true
  ]

  @doc false
  def run(args) do
    opts = parse_opts(args)
    assigns = init_assigns(opts)

    Mix.Task.run("app.start")

    unless assigns.yes do
      message = """
      This task will change existing files in your project.

      Make sure you commit your work before running it, especially if this is not a fresh phoenix project.
      """

      Mix.shell().info([:yellow, "\nNote: ", :reset, message])

      unless Mix.shell().yes?("Do you want to continue?") do
        exit(:normal)
      end
    end

    patch_files_results =
      Patcher.patch_files([
        patches_for(:common, assigns),
        patches_for(:formatter, assigns),
        patches_for(:error_tag, assigns),
        patches_for(:js_hooks, assigns),
        patches_for(:demo, assigns),
        patches_for(:catalogue, assigns)
      ])

    create_files_results = [
      create_files_for(:demo, assigns),
      create_files_for(:demo_catalogue, assigns)
    ]

    Patcher.print_results(patch_files_results ++ create_files_results)

    updated_deps = Patcher.extract_updated_deps_from_results(patch_files_results)

    if updated_deps != [] && assigns.dep_install do
      Mix.shell().info("\nThe following dependencies were updated/added to your project:\n")

      for dep <- updated_deps do
        Mix.shell().info(["  * #{dep}"])
      end

      Mix.shell().info("")

      if assigns.yes || Mix.shell().yes?("Do you want to fetch and install them now?") do
        Mix.shell().cmd("mix deps.get", [])
        Mix.shell().cmd("mix deps.compile", [])
      end
    end
  end

  defp patches_for(:common, assigns) do
    %{
      context_app: context_app,
      web_module: web_module,
      web_module_path: web_module_path,
      web_path: web_path
    } = assigns

    %{
      "config/dev.exs" => [
        Patches.add_surface_live_reload_pattern_to_endpoint_config(context_app, web_module, web_path)
      ],
      web_module_path => [
        Patches.add_import_surface_to_view_macro(web_module)
      ]
    }
  end

  defp patches_for(:formatter, %{formatter: true}) do
    %{
      "mix.exs" => [
        Patches.add_surface_formatter_to_mix_deps()
      ],
      ".formatter.exs" => [
        Patches.add_surface_inputs_to_formatter_config(),
        Patches.add_surface_to_import_deps_in_formatter_config()
      ]
    }
  end

  defp patches_for(:error_tag, %{error_tag: true, using_gettext?: true, web_module: web_module}) do
    %{
      "config/config.exs" => [
        Patches.config_error_tag(web_module)
      ]
    }
  end

  defp patches_for(:js_hooks, %{js_hooks: true, context_app: context_app, web_module: web_module}) do
    %{
      "mix.exs" => [
        Patches.add_surface_to_mix_compilers()
      ],
      "assets/js/app.js" => [
        Patches.js_hooks()
      ],
      "config/dev.exs" => [
        Patches.add_surface_to_reloadable_compilers_in_endpoint_config(context_app, web_module)
      ],
      ".gitignore" => [
        Patches.add_ignore_js_hooks_to_gitignore()
      ]
    }
  end

  defp patches_for(:catalogue, %{catalogue: true} = assigns) do
    %{context_app: context_app, web_module: web_module, web_path: web_path} = assigns

    %{
      "mix.exs" => [
        Patches.add_surface_catalogue_to_mix_deps(),
        Patches.configure_catalogue_in_mix_exs()
      ],
      "config/dev.exs" => [
        Patches.add_catalogue_live_reload_pattern_to_endpoint_config(context_app, web_module)
      ],
      "#{web_path}/router.ex" => [
        Patches.configure_catalogue_route(web_module)
      ]
    }
  end

  defp patches_for(:demo, %{demo: true} = assigns) do
    %{web_module: web_module, web_path: web_path} = assigns

    %{
      "#{web_path}/router.ex" => [
        Patches.configure_demo_route(web_module)
      ]
    }
  end

  defp patches_for(_, _), do: %{}

  defp create_files_for(:demo, %{demo: true, web_path: web_path} = assigns) do
    Patcher.create_files(assigns, [
      {"demo/hero.ex", Path.join([web_path, "components"])},
      {"demo/demo.ex", Path.join([web_path, "live"])}
    ])
  end

  defp create_files_for(:demo_catalogue, %{demo: true, catalogue: true, web_module: web_module} = assigns) do
    web_folder = web_module |> inspect() |> Macro.underscore()
    dest = Path.join(["priv/catalogue/", web_folder])

    Patcher.create_files(assigns, [
      {"demo/example01.ex", dest},
      {"demo/example02.ex", dest},
      {"demo/playground.ex", dest}
    ])
  end

  defp create_files_for(_, _), do: []

  defp parse_opts(args) do
    {opts, _parsed} = OptionParser.parse!(args, strict: @switches)
    Keyword.merge(@default_opts, opts)
  end

  defp init_assigns(opts) do
    context_app = Mix.Phoenix.context_app()
    web_path = Mix.Phoenix.web_path(context_app)
    base = Module.concat([Mix.Phoenix.base()])
    web_module = Mix.Phoenix.web_module(base)
    web_module_path = web_module_path(context_app)
    using_gettext? = using_gettext?(web_path, web_module)

    opts
    |> Map.new()
    |> Map.merge(%{
      context_app: context_app,
      web_module: web_module,
      web_module_path: web_module_path,
      web_path: web_path,
      using_gettext?: using_gettext?
    })
  end

  defp web_module_path(ctx_app) do
    web_prefix = Mix.Phoenix.web_path(ctx_app)
    [lib_prefix, web_dir] = Path.split(web_prefix)
    Path.join(lib_prefix, "#{web_dir}.ex")
  end

  defp using_gettext?(web_path, web_module) do
    file = Path.join(web_path, "views/error_helpers.ex")
    error_helper = Module.concat(web_module, ErrorHelpers)

    file
    |> ExPatcher.parse_file!()
    |> ExPatcher.enter_defmodule(error_helper)
    |> ExPatcher.enter_def(:translate_error)
    |> ExPatcher.find_code_containing("Gettext.dngettext")
    |> ExPatcher.valid?()
  end
end
