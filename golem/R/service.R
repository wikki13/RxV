rxv_api_url <- function() {
  Sys.getenv("RXV_API_URL", "http://api:7860")
}

rxv_api <- function(path) paste0(sub("/$", "", rxv_api_url()), path)

submit_to_rxv <- function(github_url, zip_path, profile) {
  req <- httr2::request(rxv_api("/api/submissions")) |>
    httr2::req_method("POST") |>
    httr2::req_timeout(30)
  if (nzchar(github_url)) {
    req <- httr2::req_body_multipart(req, github_url = github_url, profile = profile)
  } else {
    req <- httr2::req_body_multipart(req, package_zip = httr2::form_file(zip_path), profile = profile)
  }
  response <- httr2::req_perform(req)
  httr2::resp_body_json(response, simplifyVector = FALSE)
}

get_rxv_run <- function(run_id) {
  response <- httr2::request(rxv_api(paste0("/api/runs/", run_id))) |>
    httr2::req_timeout(15) |>
    httr2::req_perform()
  httr2::resp_body_json(response, simplifyVector = FALSE)
}
