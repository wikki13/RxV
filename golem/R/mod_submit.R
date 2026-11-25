#' Public submission module UI
mod_submit_ui <- function(id) {
  ns <- shiny::NS(id)
  htmltools::tagList(
    htmltools::tags$section(class = "hero-shell",
      htmltools::tags$div(class = "eyebrow", "R PACKAGE QUALITY INTELLIGENCE"),
      htmltools::tags$h1("Prove your package is ready.", htmltools::tags$span("Before CRAN does.")),
      htmltools::tags$p("Run a deep, isolated validation across package integrity, AST safety, unit tests, coverage, docs, visual snapshots, and reproducibility."),
      htmltools::tags$div(class = "hero-metrics",
        metric_card("9", "validation domains"), metric_card("0", "network access in test sandbox"), metric_card("3", "release profiles")
      )
    ),
    bslib::layout_columns(
      col_widths = c(7, 5),
      bslib::card(class = "rxv-card submit-card",
        bslib::card_header(htmltools::tagList(htmltools::tags$span(class = "step-number", "01"), htmltools::tags$strong("Package source"), htmltools::tags$span(class = "muted", "Public GitHub or source ZIP"))),
        shiny::radioButtons(ns("source_kind"), NULL, choices = c("GitHub repository" = "github", "Upload ZIP" = "zip"), selected = "github", inline = TRUE),
        shiny::conditionalPanel(sprintf("input['%s'] === 'github'", ns("source_kind")),
          shiny::textInput(ns("github_url"), "Public GitHub repository", placeholder = "https://github.com/org/package")
        ),
        shiny::conditionalPanel(sprintf("input['%s'] === 'zip'", ns("source_kind")),
          shiny::fileInput(ns("package_zip"), "Package source archive", accept = ".zip", buttonLabel = "Choose ZIP")
        ),
        htmltools::tags$div(class = "drop-note", htmltools::tags$i(class = "shield-icon", "✦"), "Archives are screened before scheduling. Package code is never executed in this UI."),
        shiny::actionButton(ns("submit"), htmltools::tagList("Start validation", htmltools::tags$span("→")), class = "btn-rxv")
      ),
      bslib::card(class = "rxv-card profile-card",
        bslib::card_header(htmltools::tagList(htmltools::tags$span(class = "step-number", "02"), htmltools::tags$strong("Validation depth"))),
        shiny::radioButtons(ns("profile"), NULL, choices = c("Rapid  ·  static + install + tests" = "rapid", "Standard  ·  full package confidence" = "standard", "Release  ·  visual + matrix + reproducibility" = "release"), selected = "standard"),
        htmltools::tags$div(class = "profile-includes", htmltools::tags$span("STANDARD INCLUDES"), htmltools::tags$ul(htmltools::tags$li("R CMD check — as CRAN"), htmltools::tags$li("testthat, coverage, lint, docs"), htmltools::tags$li("AST policy and dependency audit")))
      )
    ),
    htmltools::tags$section(class = "matrix-section",
      htmltools::tags$div(class = "section-label", "VALIDATION MATRIX"),
      htmltools::tags$div(class = "matrix-grid",
        matrix_tile("⌘", "Package integrity", "Build · install · check"), matrix_tile("◈", "AST intelligence", "Parse · complexity · risk"),
        matrix_tile("✓", "Test confidence", "testthat · coverage"), matrix_tile("◉", "Visual regression", "vdiffr · Shiny"),
        matrix_tile("¶", "Documentation", "Rd · roxygen · examples"), matrix_tile("↺", "Reproducibility", "renv · dependencies")
      )
    )
  )
}

metric_card <- function(value, label) htmltools::tags$div(class = "metric", htmltools::tags$strong(value), htmltools::tags$span(label))
matrix_tile <- function(icon, title, description) htmltools::tags$div(class = "matrix-tile", htmltools::tags$span(class = "matrix-icon", icon), htmltools::tags$strong(title), htmltools::tags$small(description))

#' Submission module server
mod_submit_server <- function(id) {
  shiny::moduleServer(id, function(input, output, session) {
    submitted <- shiny::reactiveVal(NULL)
    shiny::observeEvent(input$submit, {
      github <- trimws(input$github_url %||% "")
      zip <- input$package_zip$datapath %||% ""
      if (identical(input$source_kind, "github") && !grepl("^https://github\\.com/[^/]+/[^/]+/?$", github)) {
        shiny::showNotification("Enter a public github.com owner/repository URL.", type = "error"); return()
      }
      if (identical(input$source_kind, "zip") && !nzchar(zip)) {
        shiny::showNotification("Choose a package ZIP file.", type = "error"); return()
      }
      shinyjs::disable("submit")
      on.exit(shinyjs::enable("submit"), add = TRUE)
      result <- tryCatch(submit_to_rxv(github, zip, input$profile), error = function(e) e)
      if (inherits(result, "error")) {
        shiny::showNotification("Could not schedule validation. Please try again.", type = "error")
      } else {
        submitted(result$id)
        shiny::showNotification("Validation queued — opening live report.", type = "message")
        shiny::updateNavbarPage(session, "main_nav", selected = "Report")
      }
    })
    submitted
  })
}
