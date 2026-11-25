FROM rocker/shiny:4.4.2
WORKDIR /srv/rxv
RUN install2.r --error --skipinstalled bslib config DT golem htmltools httr2 jsonlite shiny shinyjs testthat && rm -rf /tmp/downloaded_packages
COPY golem /srv/rxv/golem
RUN R CMD INSTALL /srv/rxv/golem
EXPOSE 7860
CMD ["R", "-e", "options(shiny.port=7860, shiny.host='0.0.0.0'); rxv::run_app()"]
