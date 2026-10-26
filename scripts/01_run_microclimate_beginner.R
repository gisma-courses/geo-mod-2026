# -----------------------------------------------------------------------------
# Microclimate beginner workflow
# -----------------------------------------------------------------------------
# Goal:
# Small, runnable version of the EON microclimate workflow.
# Same conceptual chain, smaller data, fewer moving parts.
#
# Data -> stations -> DEM -> one timestamp -> interpolation -> R* -> benchmark -> export
# -----------------------------------------------------------------------------

# 0) Packages -----------------------------------------------------------------
pkgs <- c("terra", "sf", "dplyr", "tidyr", "lubridate", "ggplot2", "viridis")
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing) > 0) {
  stop("Missing packages: ", paste(missing, collapse = ", "),
       "\nRun 00_install_packages.R first.")
}
invisible(lapply(pkgs, library, character.only = TRUE))

set.seed(42)

# 1) Project paths -------------------------------------------------------------
root_dir   <- getwd()
data_dir   <- file.path(root_dir, "data")
out_dir    <- file.path(root_dir, "outputs")
fig_dir    <- file.path(out_dir, "fig")
map_dir    <- file.path(out_dir, "maps")
summary_dir <- file.path(out_dir, "summary")
for (d in c(out_dir, fig_dir, map_dir, summary_dir)) dir.create(d, showWarnings = FALSE, recursive = TRUE)

epsg <- "EPSG:25832"  # metric CRS, suitable for many German examples

# 2) Load station and temperature data -----------------------------------------
stations <- read.csv(file.path(data_dir, "stations.csv"))
temp_raw <- read.csv(file.path(data_dir, "temperature_3h.csv"), check.names = FALSE)
temp_raw$Time <- lubridate::ymd_hms(temp_raw$Time)

# Convert station table to spatial points
stations_sf <- sf::st_as_sf(stations, coords = c("x", "y"), crs = epsg, remove = FALSE)

# 3) Build a small synthetic DEM -----------------------------------------------
# DEM_scale is used for modelling scale. DEM_render is used for map output.
ext <- terra::ext(min(stations$x) - 80, max(stations$x) + 80,
                  min(stations$y) - 80, max(stations$y) + 80)
DEM_render <- terra::rast(ext, resolution = 5, crs = epsg)
xy <- terra::crds(DEM_render, df = TRUE)
DEM_values <- 240 +
  0.020 * (xy$x - min(xy$x)) +
  0.030 * (xy$y - min(xy$y)) +
  12 * sin((xy$x - min(xy$x)) / 150) +
  8  * cos((xy$y - min(xy$y)) / 120)
terra::values(DEM_render) <- DEM_values
names(DEM_render) <- "altitude"

DEM_scale <- terra::aggregate(DEM_render, fact = 4, fun = mean)
names(DEM_scale) <- "altitude"

terra::writeRaster(DEM_render, file.path(map_dir, "DEM_render_5m.tif"), overwrite = TRUE)
terra::writeRaster(DEM_scale,  file.path(map_dir, "DEM_scale_20m.tif"), overwrite = TRUE)

# Extract altitude at station positions
stations_vect <- terra::vect(stations_sf)
stations$altitude <- terra::extract(DEM_scale, stations_vect)[["altitude"]]
stations_sf$altitude <- stations$altitude

# 4) Reshape temperature table -------------------------------------------------
# Original logger table: one row per time, one column per station.
# Modelling table: one row per station, one column per timestamp.
temp_long <- temp_raw |>
  tidyr::pivot_longer(cols = -Time, names_to = "stationid", values_to = "value") |>
  dplyr::mutate(
    value  = as.numeric(value),
    ts_key = paste0("A", format(Time, "%Y%m%d%H%M%S"))
  )

temp_wide <- temp_long |>
  dplyr::select(stationid, ts_key, value) |>
  tidyr::pivot_wider(names_from = ts_key, values_from = value)

m <- dplyr::left_join(stations, temp_wide, by = "stationid")
vars <- grep("^A\\d{14}$", names(m), value = TRUE)

# Choose the timestamp with most valid station values
data_density <- sapply(vars, function(v) sum(is.finite(m[[v]])))
pick_ts <- vars[which.max(data_density)]
message("Chosen timestamp: ", pick_ts)

# 5) Helper functions ----------------------------------------------------------
pretty_time <- function(x) {
  as.character(as.POSIXct(substr(x, 2, 15), format = "%Y%m%d%H%M%S", tz = "UTC"))
}

rmse <- function(obs, pred) {
  ok <- is.finite(obs) & is.finite(pred)
  sqrt(mean((obs[ok] - pred[ok])^2))
}

make_grid <- function(r) {
  g <- terra::as.data.frame(r, xy = TRUE, cells = TRUE, na.rm = FALSE)
  names(g) <- c("cell", "x", "y", "altitude")
  g
}

idw_predict <- function(train, newdata, power = 2) {
  # Manual IDW: closer stations receive stronger weight.
  out <- numeric(nrow(newdata))
  for (i in seq_len(nrow(newdata))) {
    d <- sqrt((train$x - newdata$x[i])^2 + (train$y - newdata$y[i])^2)
    if (any(d == 0)) {
      out[i] <- train$value[which.min(d)]
    } else {
      w <- 1 / (d^power)
      out[i] <- sum(w * train$value) / sum(w)
    }
  }
  out
}

trend_predict <- function(train, newdata) {
  # External drift concept, simplified: temperature as function of altitude.
  fit <- lm(value ~ altitude, data = train)
  as.numeric(predict(fit, newdata = newdata))
}

ked_like_predict <- function(train, newdata) {
  # KED idea, simplified for beginners:
  # 1) explain temperature by altitude
  # 2) interpolate the remaining residuals spatially
  # 3) add drift prediction + residual correction
  fit <- lm(value ~ altitude, data = train)
  train$resid <- residuals(fit)
  drift <- as.numeric(predict(fit, newdata = newdata))
  resid_pred <- idw_predict(
    train = data.frame(x = train$x, y = train$y, value = train$resid),
    newdata = newdata,
    power = 2
  )
  drift + resid_pred
}

make_raster_from_values <- function(template, values, name) {
  r <- template[[1]]
  terra::values(r) <- values
  names(r) <- name
  r
}

smooth_dem <- function(r, radius_m) {
  res_m <- mean(terra::res(r))
  n <- max(3, 2 * ceiling(radius_m / res_m) + 1)
  w <- matrix(1, nrow = n, ncol = n)
  terra::focal(r, w = w, fun = mean, na.policy = "omit", fillvalue = NA)
}

loocv_trend_rmse <- function(df) {
  pred <- rep(NA_real_, nrow(df))
  for (i in seq_len(nrow(df))) {
    train <- df[-i, ]
    test  <- df[i, ]
    pred[i] <- trend_predict(train, test)
  }
  rmse(df$value, pred)
}

loocv_method <- function(df, method) {
  pred <- rep(NA_real_, nrow(df))
  for (i in seq_len(nrow(df))) {
    train <- df[-i, ]
    test  <- df[i, ]
    pred[i] <- switch(
      method,
      mean     = mean(train$value, na.rm = TRUE),
      trend    = trend_predict(train, test),
      idw      = idw_predict(train, test),
      ked_like = ked_like_predict(train, test)
    )
  }
  rmse(df$value, pred)
}

# 6) Prepare one modelling timestamp ------------------------------------------
train_one <- m |>
  dplyr::transmute(
    stationid = stationid,
    x = x,
    y = y,
    altitude = altitude,
    value = .data[[pick_ts]]
  ) |>
  dplyr::filter(is.finite(value), is.finite(altitude))

grid_render <- make_grid(DEM_render)

# 7) Interpolate maps ----------------------------------------------------------
pred_idw      <- idw_predict(train_one, grid_render)
pred_trend    <- trend_predict(train_one, grid_render)
pred_ked_like <- ked_like_predict(train_one, grid_render)

r_idw      <- make_raster_from_values(DEM_render, pred_idw, "idw")
r_trend    <- make_raster_from_values(DEM_render, pred_trend, "trend")
r_ked_like <- make_raster_from_values(DEM_render, pred_ked_like, "ked_like")

terra::writeRaster(r_idw,      file.path(map_dir, "temperature_idw.tif"), overwrite = TRUE)
terra::writeRaster(r_trend,    file.path(map_dir, "temperature_trend.tif"), overwrite = TRUE)
terra::writeRaster(r_ked_like, file.path(map_dir, "temperature_ked_like.tif"), overwrite = TRUE)

# 8) Tune R* -------------------------------------------------------------------
# R means: over how much space is the DEM smoothed before it enters the model?
# Smaller R = local terrain. Larger R = broader terrain setting.
R_candidates <- c(20, 40, 80, 120)
R_results <- lapply(R_candidates, function(R) {
  dem_R <- smooth_dem(DEM_scale, R)
  alt_R <- terra::extract(dem_R, stations_vect)[[1]]
  df_R <- train_one
  df_R$altitude <- alt_R[match(df_R$stationid, stations$stationid)]
  data.frame(R = R, RMSE = loocv_trend_rmse(df_R))
}) |>
  dplyr::bind_rows()

R_star <- R_results$R[which.min(R_results$RMSE)]
write.csv(R_results, file.path(summary_dir, "R_tuning_results.csv"), row.names = FALSE)

# 9) Benchmark methods ---------------------------------------------------------
bench <- data.frame(
  method = c("mean", "trend", "idw", "ked_like"),
  RMSE = c(
    loocv_method(train_one, "mean"),
    loocv_method(train_one, "trend"),
    loocv_method(train_one, "idw"),
    loocv_method(train_one, "ked_like")
  )
)
bench <- bench[order(bench$RMSE), ]
write.csv(bench, file.path(summary_dir, "benchmark_methods.csv"), row.names = FALSE)

# 10) Figures ------------------------------------------------------------------
panel_df <- dplyr::bind_rows(
  cbind(terra::as.data.frame(r_idw, xy = TRUE), method = "IDW"),
  cbind(terra::as.data.frame(r_trend, xy = TRUE), method = "Trend altitude"),
  cbind(terra::as.data.frame(r_ked_like, xy = TRUE), method = "KED-like")
)
names(panel_df)[3] <- "temperature"

p_map <- ggplot(panel_df, aes(x = x, y = y, fill = temperature)) +
  geom_raster() +
  geom_point(data = train_one, aes(x = x, y = y), inherit.aes = FALSE, size = 1.5) +
  facet_wrap(~ method, nrow = 1) +
  coord_equal() +
  scale_fill_viridis_c(option = "C") +
  labs(
    title = paste("Interpolated air temperature", pretty_time(pick_ts)),
    fill = "°C"
  ) +
  theme_minimal()

ggsave(file.path(fig_dir, "temperature_interpolation_panel.png"), p_map, width = 10, height = 4, dpi = 160)
print(p_map)

p_R <- ggplot(R_results, aes(x = R, y = RMSE)) +
  geom_line() +
  geom_point(size = 2) +
  geom_vline(xintercept = R_star, linetype = 2) +
  labs(title = "R* tuning", subtitle = paste("Best R =", R_star, "m"), x = "R in metres", y = "LOOCV RMSE") +
  theme_minimal()

ggsave(file.path(fig_dir, "R_tuning_curve.png"), p_R, width = 6, height = 4, dpi = 160)
print(p_R)

p_bench <- ggplot(bench, aes(x = reorder(method, RMSE), y = RMSE)) +
  geom_col() +
  coord_flip() +
  labs(title = "Method benchmark", x = NULL, y = "LOOCV RMSE") +
  theme_minimal()

ggsave(file.path(fig_dir, "benchmark_methods.png"), p_bench, width = 6, height = 4, dpi = 160)
print(p_bench)

# 11) Console summary ----------------------------------------------------------
cat("\n--- Finished ---\n")
cat("Timestamp: ", pretty_time(pick_ts), "\n")
cat("Stations used: ", nrow(train_one), "\n")
cat("R*: ", R_star, "m\n")
cat("Best method: ", bench$method[1], " RMSE=", round(bench$RMSE[1], 3), "\n", sep = "")
cat("Outputs written to: ", out_dir, "\n")
