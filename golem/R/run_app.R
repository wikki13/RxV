#' Run the Project RxV Golem application
#'
#' @param ... Arguments passed to [shiny::shinyApp()].
#' @export
run_app <- function(...) {
  shiny::addResourcePath("www", app_sys("app/www"))
  shiny::shinyApp(ui = app_ui, server = app_server, ...)
}
