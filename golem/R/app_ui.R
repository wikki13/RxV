app_ui <- function(request) {
  bslib::page_navbar(
  title = htmltools::tagList(htmltools::tags$span(class = "rxv-mark", "RxV"), " Project RxV"),
  id = "main_nav",
  theme = bslib::bs_theme(version = 5, bg = "#070A12", fg = "#F4F7FF", primary = "#8B5CF6", base_font = bslib::font_google("DM Sans")),
  header = htmltools::tagList(
    shinyjs::useShinyjs(),
    htmltools::tags$link(rel = "stylesheet", href = "www/rxv.css"),
    htmltools::tags$script(src = "www/rxv.js")
  ),
  bslib::nav_panel("Validate", mod_submit_ui("submit")),
  bslib::nav_panel("Report", mod_report_ui("report")),
  bslib::nav_spacer(),
  bslib::nav_item(htmltools::tags$span(class = "nav-status", htmltools::tags$i(class = "status-dot"), " Isolated runner")),
    footer = htmltools::tags$footer(class = "rxv-footer", "Project RxV · Public R package validation · Code runs only in an ephemeral, no-egress sandbox")
  )
}
