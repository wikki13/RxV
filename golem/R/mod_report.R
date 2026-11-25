#' Live validation report UI
mod_report_ui <- function(id) {
  ns <- shiny::NS(id)
  htmltools::tagList(
    htmltools::tags$section(class = "report-hero",
      htmltools::tags$div(class = "eyebrow", "LIVE VALIDATION REPORT"),
      htmltools::tags$h2(shiny::textOutput(ns("title"), inline = TRUE)),
      htmltools::tags$div(class = "run-meta", shiny::uiOutput(ns("meta")))
    ),
    shiny::uiOutput(ns("progress")),
    bslib::layout_columns(
      col_widths = c(4, 8),
      bslib::card(class = "rxv-card score-card", shiny::uiOutput(ns("score"))),
      bslib::card(class = "rxv-card", bslib::card_header("Validation suites"), shiny::uiOutput(ns("suites")))
    ),
    bslib::card(class = "rxv-card findings-card", bslib::card_header("Findings"), DT::DTOutput(ns("findings")))
  )
}

#' Live validation report server
mod_report_server <- function(id, run_id) {
  shiny::moduleServer(id, function(input, output, session) {
    result <- shiny::reactiveVal(NULL)
    timer <- shiny::reactiveTimer(3000, session)
    shiny::observe({
      timer()
      id <- run_id()
      if (!is.null(id)) result(tryCatch(get_rxv_run(id), error = function(e) list(status = "unavailable", error = "Report service is unreachable.")))
    })
    output$title <- shiny::renderText({ if (is.null(run_id())) "Your next release starts here" else paste("Run", substr(run_id(), 1, 12)) })
    output$meta <- shiny::renderUI({
      r <- result(); if (is.null(r)) return(htmltools::tags$span("Submit a package to begin."))
      htmltools::tagList(htmltools::tags$span(class = paste("status-pill", r$status), toupper(r$status)), htmltools::tags$span(" · "), htmltools::tags$span(r$source_ref %||% ""), htmltools::tags$span(" · "), htmltools::tags$span(toupper(r$profile %||% "")))
    })
    output$progress <- shiny::renderUI({
      r <- result(); if (is.null(r) || r$status %in% c("passed", "failed", "error")) return(NULL)
      htmltools::tags$div(class = "queue-progress", htmltools::tags$span(class = "pulse"), "Sandbox is preparing an isolated R environment. This report updates automatically.")
    })
    output$score <- shiny::renderUI({
      report <- result()$report %||% NULL
      if (is.null(report)) return(htmltools::tags$div(class = "empty-score", "Quality score will appear when validation completes."))
      htmltools::tags$div(class = "score-content", htmltools::tags$span("RXV QUALITY SCORE"), htmltools::tags$strong(paste0(report$score %||% "—", "/100")), htmltools::tags$p(report$verdict %||% "Complete"), htmltools::tags$small("Score weights correctness, reproducibility, maintainability and release risk."))
    })
    output$suites <- shiny::renderUI({
      suites <- result()$report$suites %||% list()
      if (!length(suites)) return(htmltools::tags$p(class = "muted", "Suite results will arrive as the runner completes."))
      htmltools::tags$div(class = "suite-list", lapply(suites, function(s) htmltools::tags$div(class = "suite-row", htmltools::tags$span(class = paste("suite-status", s$status), "●"), htmltools::tags$div(htmltools::tags$strong(s$name), htmltools::tags$small(s$summary)), htmltools::tags$span(class = "suite-state", toupper(s$status)))))
    })
    output$findings <- DT::renderDT({
      rows <- result()$report$findings %||% list()
      if (!length(rows)) return(DT::datatable(data.frame(Status = "No findings yet"), options = list(dom = "t"), rownames = FALSE))
      table <- do.call(rbind, lapply(rows, function(x) data.frame(Severity = x$severity, Rule = x$rule, Location = paste0(x$file, ":", x$line), Finding = x$message, stringsAsFactors = FALSE)))
      DT::datatable(table, options = list(pageLength = 6, dom = "tip"), rownames = FALSE, class = "compact")
    })
  })
}
