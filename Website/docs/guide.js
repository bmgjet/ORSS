// Rom Sim Studio guide: the contents down the left and the previous / next links, from one list, so every page has them.
(function () {
  const pages = [
    ["Start here", [
      ["index.html", "Guide home"],
      ["getting-started.html", "Getting started"],
      ["modes.html", "Simulator and Tuner modes"],
    ]],
    ["Writing and simulating ROMs", [
      ["simulator.html", "The workbench"],
      ["debugging.html", "Running, stepping and breakpoints"],
      ["memory.html", "Memory, trace and hit trace"],
      ["new-rom.html", "Creating a custom ROM"],
      ["setup.html", "Setting up a ROM"],
      ["modules.html", "Every function and module"],
      ["modules-p13.html", "Every function and module: P13"],
    ]],
    ["Tuning a car", [
      ["tuning.html", "Tables and settings"],
      ["calibration.html", "Definitions, Detect and tools"],
      ["datalogging.html", "Datalogging"],
      ["remote.html", "Remote control and serial commands"],
      ["dyno.html", "Virtual dyno"],
      ["gauges.html", "Gauges, graph and widgets"],
      ["emulator.html", "Emulators and flashing"],
    ]],
    ["More", [
      ["projects.html", "Projects and saving"],
      ["tools.html", "Bin tool, Compare, Import maps"],
      ["settings.html", "Settings"],
      ["shortcuts.html", "Keyboard shortcuts"],
      ["plugins.html", "Plugins"],
      ["mcp.html", "MCP server and command line"],
      ["troubleshooting.html", "Troubleshooting"],
      ["licence.html", "Licence"],
    ]],
  ];
  const here = (location.pathname.split("/").pop() || "index.html").toLowerCase();
  const flat = pages.flatMap(g => g[1]);
  const side = document.querySelector("nav.side");
  if (side) {
    side.innerHTML = pages.map(([head, list]) =>
      `<h4>${head}</h4>` + list.map(([href, title]) => `<a href="${href}"${href === here ? ' class="on"' : ""}>${title}</a>`).join("")).join("");
  }
  const at = flat.findIndex(p => p[0] === here);
  const main = document.querySelector("main");
  if (main && at >= 0) {
    const prev = flat[at - 1], next = flat[at + 1];
    const pager = document.createElement("div");
    pager.className = "pager";
    pager.innerHTML = (prev ? `<a href="${prev[0]}"><small>Previous</small>${prev[1]}</a>` : "<span></span>") +
                      (next ? `<a href="${next[0]}"><small>Next</small>${next[1]}</a>` : "<span></span>");
    const foot = main.querySelector("footer");
    main.insertBefore(pager, foot);
  }
  const btn = document.querySelector(".menu-btn");
  if (btn && side) btn.addEventListener("click", () => side.classList.toggle("open"));
})();
