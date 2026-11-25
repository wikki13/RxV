`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x

app_sys <- function(...) system.file(..., package = "rxv")
