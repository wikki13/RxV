FROM rocker/r-ver:4.4.2
ENV DEBIAN_FRONTEND=noninteractive RENV_CONFIG_REPOS_OVERRIDE=https://packagemanager.posit.co/cran/latest
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates pandoc libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev \
    libharfbuzz-dev libfribidi-dev libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    chromium fonts-liberation python3 python3-pip && rm -rf /var/lib/apt/lists/*
RUN R -q -e "install.packages(c('jsonlite','testthat','tinytest','RUnit','covr','lintr','cyclocomp','rcmdcheck','roxygen2','pkgload','goodpractice','vdiffr','shinytest2','renv','spelling','urlchecker','pkgdown'), Ncpus=2)"
WORKDIR /srv/runner
COPY requirements.txt ./
RUN pip3 install --break-system-packages --no-cache-dir -r requirements.txt && useradd --create-home --uid 10001 rxv
COPY service.py validate.R ./
RUN mkdir -p /data/uploads /data/reports /var/lib/rxv && chown -R rxv:rxv /srv/runner /data /var/lib/rxv
USER rxv
EXPOSE 8081
CMD ["uvicorn", "service:app", "--host", "0.0.0.0", "--port", "8081"]
