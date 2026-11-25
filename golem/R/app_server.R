app_server <- function(input, output, session) {
  run_id <- mod_submit_server("submit")
  mod_report_server("report", run_id)
}
