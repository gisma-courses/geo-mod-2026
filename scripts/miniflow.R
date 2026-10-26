library(sf)
library(terra)
library(gstat)
library(randomForest)

m   <- readRDS("data/climdata.rds")
dem <- rast("data/DEM1.tif")
names(dem) <- "altitude"

m$temp <- m[["A20230830"]]

m <- st_transform(m, crs(dem))
m$altitude <- terra::extract(dem, terra::vect(m))$altitude

pts <- m[!is.na(m$temp) & !is.na(m$altitude), c("temp", "altitude")]

area <- st_sf(geometry = st_buffer(st_convex_hull(st_union(st_geometry(pts))), 20))

dem <- crop(dem, vect(area))
dem <- mask(dem, vect(area))
names(dem) <- "altitude"

xy <- st_coordinates(pts)
pts$x <- xy[, 1]
pts$y <- xy[, 2]

grid <- as.data.frame(dem, xy = TRUE, cells = TRUE, na.rm = FALSE)
names(grid)[4] <- "altitude"
grid <- grid[!is.na(grid$altitude), ]

grid_sf <- st_as_sf(grid, coords = c("x", "y"), crs = st_crs(pts), remove = FALSE)

make_map <- function(pred, name) {
  r <- dem
  values(r) <- NA
  values(r)[grid$cell] <- pred
  names(r) <- name
  r
}

rmse_fun <- function(e) {
  sqrt(mean(e * e, na.rm = TRUE))
}

fit_lm <- lm(temp ~ altitude, data = st_drop_geometry(pts))
map_lm <- predict(dem, fit_lm)
names(map_lm) <- "LM_altitude"

vor_df <- gstat::idw(
  temp ~ 1,
  locations = pts,
  newdata = grid_sf,
  nmax = 1
)

map_vor <- make_map(vor_df$var1.pred, "Voronoi")

idw_df <- gstat::idw(
  temp ~ 1,
  locations = pts,
  newdata = grid_sf,
  nmax = 4
)

map_idw <- make_map(idw_df$var1.pred, "IDW")

fit_rf <- randomForest(
  temp ~ x + y + altitude,
  data = st_drop_geometry(pts),
  ntree = 200
)

rf_pred <- predict(fit_rf, newdata = grid)
map_rf <- make_map(rf_pred, "RF_warning")

lm_cv <- rep(NA, nrow(pts))
rf_cv <- rep(NA, nrow(pts))

for (i in 1:nrow(pts)) {
  train <- pts[-i, ]
  test  <- pts[i, ]
  
  fit_lm_i <- lm(temp ~ altitude, data = st_drop_geometry(train))
  lm_cv[i] <- predict(fit_lm_i, newdata = st_drop_geometry(test))
  
  fit_rf_i <- randomForest(
    temp ~ x + y + altitude,
    data = st_drop_geometry(train),
    ntree = 200
  )
  rf_cv[i] <- predict(fit_rf_i, newdata = st_drop_geometry(test))
}

vor_model <- gstat::gstat(
  formula = temp ~ 1,
  locations = pts,
  nmax = 1,
  set = list(idp = 2)
)

vor_cv <- gstat::gstat.cv(vor_model, nfold = nrow(pts))

idw_model <- gstat::gstat(
  formula = temp ~ 1,
  locations = pts,
  nmax = 4,
  set = list(idp = 2)
)

idw_cv <- gstat::gstat.cv(idw_model, nfold = nrow(pts))

rmse <- data.frame(
  model = c("LM altitude", "Voronoi", "IDW", "RF warning"),
  RMSE = c(
    rmse_fun(pts$temp - lm_cv),
    rmse_fun(vor_cv$residual),
    rmse_fun(idw_cv$residual),
    rmse_fun(pts$temp - rf_cv)
  )
)

maps <- c(map_vor, map_idw, map_lm, map_rf)
z <- range(c(pts$temp - 1, pts$temp + 1), na.rm = TRUE)

par(mfrow = c(2, 2))

for (i in 1:nlyr(maps)) {
  plot(maps[[i]], range = z, main = names(maps)[i])
  points(pts, pch = 19, cex = 0.8)
}

par(mfrow = c(1, 1))

print(rmse)