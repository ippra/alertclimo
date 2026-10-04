library(tidyverse)

source(here::here("00_paths.R"))

# Dashboard Assembly -----------------------------------------------------------
# Copies the hand-edited front end in site/ and 05's data into one static
# directory. Computes nothing.
#
# Writes outputs/06_site/ - plain static files, no server code. Preview:
#   python3 preview.py

# Which deployment this build is for. The beta on GitHub Pages is built with
# NAC_CHANNEL=beta, which labels the masthead and asks search engines not to
# index it, so the beta never competes with the production site in search.
# Unset, the build is production: the same site with neither.
channel <- Sys.getenv("NAC_CHANNEL", "production")

if (!channel %in% c("production", "beta")) {
  stop("NAC_CHANNEL is `", channel, "`; use `beta` or leave it unset.")
}

data_in <- file.path(outputs, "05_site_data")
out <- file.path(outputs, "06_site")

manifest_path <- file.path(data_in, "manifest.json")
if (!file.exists(manifest_path)) {
  stop("No site data - run 05_build_site_data.R first.")
}

manifest <- jsonlite::read_json(manifest_path)

# The stamp on every asset URL: the data build, plus a hash of the front end,
# so a change to either gives browsers a new URL to fetch.
stamped <- c("index.html", "engine.js", "engine.css")
hash_file <- tempfile()
file.path(site_src, stamped) |>
  tools::md5sum() |>
  write_lines(hash_file)
site_hash <- str_sub(tools::md5sum(hash_file), 1, 6)
build <- paste0(manifest$build, "-", site_hash)

# Every file the manifest lists must be on disk, or picking that product would
# fail in the browser rather than here.
grid_listed <- manifest$products |>
  map("grid") |>
  compact() |>
  map(\(g) map_chr(g, "file")) |>
  unlist(use.names = FALSE)
listed <- c(
  map_chr(manifest$products, "file"),
  "counties.geojson", "offices.geojson", "states.geojson",
  file.path("grid", c(grid_listed, "mask.bin.gz", "county.bin.gz"))
)
missing_files <- listed[!file.exists(file.path(data_in, listed))]
if (length(missing_files) > 0) {
  print(missing_files)
  stop("Files above are in the manifest but not in ", data_in, ".")
}

# Assemble ---------------------------------------------------------------------
# Built beside the live directory and swapped in at the end, so a host serving
# outputs/06_site during a rebuild never sees a half-copied site.
staging <- paste0(out, ".next")
unlink(staging, recursive = TRUE)
dir.create(staging, recursive = TRUE)

invisible(file.copy(
  list.files(site_src, full.names = TRUE),
  staging,
  recursive = TRUE
))
invisible(file.copy(data_in, staging, recursive = TRUE))
invisible(file.rename(
  file.path(staging, "05_site_data"),
  file.path(staging, "data")
))

# Stamped asset URLs change with each build, so a host may cache engine.js and
# engine.css indefinitely. index.html cannot stamp itself and must be served
# with Cache-Control: no-cache.
for (file in stamped) {
  path <- file.path(staging, file)
  read_file(path) |>
    str_replace_all(fixed("__BUILD__"), build) |>
    write_file(path)
}

# The Beta badge ships hidden, so a production build needs no edit to drop it.
if (channel == "beta") {
  index_path <- file.path(staging, "index.html")
  index_html <- read_file(index_path)
  badge <- "<span class=\"brand-beta\" hidden>"
  viewport <- "<meta name=\"viewport\""
  noindex <- "<meta name=\"robots\" content=\"noindex, nofollow\">\n"

  if (str_count(index_html, fixed(badge)) != 1) {
    stop("index.html has no single hidden Beta badge.")
  }
  if (str_count(index_html, fixed(viewport)) != 1) {
    stop("index.html has no single viewport line.")
  }

  index_html |>
    str_replace(fixed(badge), "<span class=\"brand-beta\">") |>
    str_replace(fixed(viewport), paste0(noindex, viewport)) |>
    write_file(index_path)
  robots <- c("User-agent: *", "Disallow: /")
  write_lines(robots, file.path(staging, "robots.txt"))
}

# Guards -----------------------------------------------------------------------
published <- list.files(staging, recursive = TRUE, all.files = TRUE)

leaked <- published[
  str_detect(published, "\\.(R|rds|csv|part|DS_Store)$|(^|/)\\.git")
]
if (length(leaked) > 0) {
  print(leaked)
  stop("Files above do not belong in the published site.")
}

unstamped <- stamped |>
  keep(\(f) str_detect(read_file(file.path(staging, f)), fixed("__BUILD__")))
if (length(unstamped) > 0) {
  print(unstamped)
  stop("Files above still carry the __BUILD__ placeholder.")
}

unlink(out, recursive = TRUE)
invisible(file.rename(staging, out))

site_mb <- sum(file.size(file.path(out, published))) / 1e6
message(
  "Site (", channel, "): ", length(published), " files, ",
  round(site_mb, 1), " MB, build ", build
)
