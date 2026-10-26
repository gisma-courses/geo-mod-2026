# -----------------------------------------------------------------------------
# HARZ WARMUP: Mikroklima in R
# -----------------------------------------------------------------------------
# Start im RStudio-Projekt-Root.
# Benötigte Dateien:
#   data/stations.csv
#   data/temperature_3h.csv
# Ergebnis:
#   outputs/fig/*.png
#   outputs/maps/*.tif
#   outputs/summary/*.csv
# -----------------------------------------------------------------------------

# 0 Pakete --------------------------------------------------------------------

pakete <- c("terra", "sf", "dplyr", "tidyr", "lubridate", "ggplot2", "viridis")
fehlen <- pakete[!pakete %in% rownames(installed.packages())]
if (length(fehlen) > 0) install.packages(fehlen)
invisible(lapply(pakete, library, character.only = TRUE))

set.seed(42)

# 1 Projektordner --------------------------------------------------------------

root <- getwd()
data_dir <- file.path(root, "data")
out_dir  <- file.path(root, "outputs")
fig_dir  <- file.path(out_dir, "fig")
map_dir  <- file.path(out_dir, "maps")
sum_dir  <- file.path(out_dir, "summary")

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(map_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(sum_dir, recursive = TRUE, showWarnings = FALSE)

crs_m <- "EPSG:25832"   # metrisches Koordinatensystem: Meter statt Grad

# 2 Daten laden ----------------------------------------------------------------

stations <- read.csv(file.path(data_dir, "stations.csv"))
temp <- read.csv(file.path(data_dir, "temperature_3h.csv"), check.names = FALSE)
temp$Time <- lubridate::ymd_hms(temp$Time)

stations_sf <- sf::st_as_sf(stations, coords = c("x", "y"), crs = crs_m, remove = FALSE)

# 3 Kleine DEM-Fläche erzeugen -------------------------------------------------
# Für die Übung wird kein externes DEM geladen.
# Das Höhenmodell wird aus x/y-Koordinaten synthetisch erzeugt.

gebiet <- terra::ext(
  min(stations$x) - 80, max(stations$x) + 80,
  min(stations$y) - 80, max(stations$y) + 80
)

dem <- terra::rast(gebiet, resolution = 5, crs = crs_m)
xy <- terra::crds(dem, df = TRUE)

terra::values(dem) <- 240 +
  0.020 * (xy$x - min(xy$x)) +
  0.030 * (xy$y - min(xy$y)) +
  12 * sin((xy$x - min(xy$x)) / 150) +
  8  * cos((xy$y - min(xy$y)) / 120)

names(dem) <- "altitude"

dem_20m <- terra::aggregate(dem, fact = 4, fun = mean)
names(dem_20m) <- "altitude"

terra::writeRaster(dem,     file.path(map_dir, "dem_5m.tif"),  overwrite = TRUE)
terra::writeRaster(dem_20m, file.path(map_dir, "dem_20m.tif"), overwrite = TRUE)

stations$altitude <- terra::extract(dem_20m, terra::vect(stations_sf))[["altitude"]]

# 4 Temperaturtabelle umbauen --------------------------------------------------
# Ausgangsform:     Zeit x Stationen
# Modellform:       Stationen x Zeitpunkte

temp_long <- temp |>
  tidyr::pivot_longer(-Time, names_to = "stationid", values_to = "value") |>
  dplyr::mutate(
    value = as.numeric(value),
    ts = paste0("A", format(Time, "%Y%m%d%H%M%S"))
  )

temp_wide <- temp_long |>
  dplyr::select(stationid, ts, value) |>
  tidyr::pivot_wider(names_from = ts, values_from = value)

m <- dplyr::left_join(stations, temp_wide, by = "stationid")
zeitspalten <- grep("^A[0-9]{14}$", names(m), value = TRUE)

# Der vollständigste Zeitpunkt wird automatisch gewählt.
gueltige_werte <- sapply(zeitspalten, function(z) sum(is.finite(m[[z]])))
zeitpunkt <- zeitspalten[which.max(gueltige_werte)]

cat("Gewählter Zeitpunkt:", zeitpunkt, "\n")

# 5 Ein Zeitpunkt für das Modell ----------------------------------------------

train <- m |>
  dplyr::transmute(
    stationid,
    x,
    y,
    altitude,
    value = .data[[zeitpunkt]]
  ) |>
  dplyr::filter(is.finite(value), is.finite(altitude))

grid <- terra::as.data.frame(dem, xy = TRUE, cells = TRUE, na.rm = FALSE)
names(grid) <- c("cell", "x", "y", "altitude")

# 6 Drei einfache Modelle ------------------------------------------------------

idw <- function(train, grid, power = 2) {
  pred <- numeric(nrow(grid))
  for (i in seq_len(nrow(grid))) {
    d <- sqrt((train$x - grid$x[i])^2 + (train$y - grid$y[i])^2)
    if (any(d == 0)) {
      pred[i] <- train$value[which.min(d)]
    } else {
      w <- 1 / d^power
      pred[i] <- sum(w * train$value) / sum(w)
    }
  }
  pred
}

trend <- function(train, grid) {
  fit <- lm(value ~ altitude, data = train)
  as.numeric(predict(fit, newdata = grid))
}

ked_simple <- function(train, grid) {
  fit <- lm(value ~ altitude, data = train)
  train$resid <- residuals(fit)
  drift <- as.numeric(predict(fit, newdata = grid))
  resid <- idw(
    train = data.frame(x = train$x, y = train$y, value = train$resid),
    grid = grid
  )
  drift + resid
}

# IDW: Nähe zählt.
# Trend: Höhe erklärt Temperatur.
# KED-simple: Höhe erklärt den groben Trend, IDW ergänzt lokale Restfehler.

pred_idw   <- idw(train, grid)
pred_trend <- trend(train, grid)
pred_ked   <- ked_simple(train, grid)

# 7 Raster speichern -----------------------------------------------------------

make_raster <- function(values, name) {
  r <- dem
  terra::values(r) <- values
  names(r) <- name
  r
}

r_idw   <- make_raster(pred_idw,   "idw")
r_trend <- make_raster(pred_trend, "trend")
r_ked   <- make_raster(pred_ked,   "ked_simple")

terra::writeRaster(r_idw,   file.path(map_dir, "temperature_idw.tif"),        overwrite = TRUE)
terra::writeRaster(r_trend, file.path(map_dir, "temperature_trend.tif"),      overwrite = TRUE)
terra::writeRaster(r_ked,   file.path(map_dir, "temperature_ked_simple.tif"), overwrite = TRUE)

# 8 Modellvergleich mit Leave-One-Out -----------------------------------------
# Eine Station wird entfernt, aus den anderen vorhergesagt, Fehler berechnet.

rmse <- function(obs, pred) sqrt(mean((obs - pred)^2, na.rm = TRUE))

loocv <- function(train, methode) {
  pred <- rep(NA_real_, nrow(train))
  for (i in seq_len(nrow(train))) {
    train_i <- train[-i, ]
    test_i  <- train[i, ]
    pred[i] <- switch(
      methode,
      mean  = mean(train_i$value),
      idw   = idw(train_i, test_i),
      trend = trend(train_i, test_i),
      ked   = ked_simple(train_i, test_i)
    )
  }
  rmse(train$value, pred)
}

benchmark <- data.frame(
  methode = c("mean", "idw", "trend", "ked"),
  RMSE = c(
    loocv(train, "mean"),
    loocv(train, "idw"),
    loocv(train, "trend"),
    loocv(train, "ked")
  )
)

benchmark <- benchmark[order(benchmark$RMSE), ]
write.csv(benchmark, file.path(sum_dir, "benchmark_methods.csv"), row.names = FALSE)

# 9 R* sehr einfach testen -----------------------------------------------------
# R* fragt: Welche Geländeglättung passt besser zum Temperaturmuster?

smooth_dem <- function(r, radius_m) {
  zellgroesse <- mean(terra::res(r))
  n <- max(3, 2 * ceiling(radius_m / zellgroesse) + 1)
  terra::focal(r, w = matrix(1, n, n), fun = mean, na.policy = "omit", fillvalue = NA)
}

R_werte <- c(20, 40, 80, 120)
R_test <- lapply(R_werte, function(R) {
  dem_R <- smooth_dem(dem_20m, R)
  train_R <- train
  train_R$altitude <- terra::extract(dem_R, terra::vect(stations_sf))[[1]][match(train_R$stationid, stations$stationid)]
  data.frame(R = R, RMSE = loocv(train_R, "trend"))
}) |>
  dplyr::bind_rows()

R_star <- R_test$R[which.min(R_test$RMSE)]
write.csv(R_test, file.path(sum_dir, "R_tuning_results.csv"), row.names = FALSE)

# 10 Abbildungen ---------------------------------------------------------------

karten_df <- dplyr::bind_rows(
  cbind(terra::as.data.frame(r_idw,   xy = TRUE), methode = "IDW"),
  cbind(terra::as.data.frame(r_trend, xy = TRUE), methode = "Trend: Höhe"),
  cbind(terra::as.data.frame(r_ked,   xy = TRUE), methode = "KED einfach")
)
names(karten_df)[3] <- "temperature"

p1 <- ggplot(karten_df, aes(x, y, fill = temperature)) +
  geom_raster() +
  geom_point(data = train, aes(x, y), inherit.aes = FALSE, size = 1.5) +
  facet_wrap(~ methode, nrow = 1) +
  coord_equal() +
  scale_fill_viridis_c(option = "C") +
  labs(title = "Interpolierte Lufttemperatur", fill = "°C") +
  theme_minimal()

ggsave(file.path(fig_dir, "temperature_interpolation_panel.png"), p1, width = 10, height = 4, dpi = 160)
print(p1)

p2 <- ggplot(R_test, aes(R, RMSE)) +
  geom_line() +
  geom_point(size = 2) +
  geom_vline(xintercept = R_star, linetype = 2) +
  labs(title = "R*-Test", subtitle = paste("Bestes R =", R_star, "m"), x = "R in Meter", y = "RMSE") +
  theme_minimal()

ggsave(file.path(fig_dir, "R_tuning_curve.png"), p2, width = 6, height = 4, dpi = 160)
print(p2)

p3 <- ggplot(benchmark, aes(reorder(methode, RMSE), RMSE)) +
  geom_col() +
  coord_flip() +
  labs(title = "Modellvergleich", x = NULL, y = "RMSE") +
  theme_minimal()

ggsave(file.path(fig_dir, "benchmark_methods.png"), p3, width = 6, height = 4, dpi = 160)
print(p3)

# 11 Ende ----------------------------------------------------------------------

cat("\nFertig.\n")
cat("Stationen:", nrow(train), "\n")
cat("Bestes R*:", R_star, "m\n")
cat("Bestes Modell:", benchmark$methode[1], "RMSE =", round(benchmark$RMSE[1], 3), "\n")
cat("Ergebnisse:", out_dir, "\n")
