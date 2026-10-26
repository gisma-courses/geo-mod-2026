# =============================================================================
# Mikroklima-Warmup
# Punktmessungen -> räumliche Ergebnisraster -> Modellvergleich
# =============================================================================
#
# Dieses Skript ist absichtlich klein gehalten.
# Es zeigt die minimale technische Kette, mit der eine typische Ausgangsfrage
# bearbeitbar wird:
#
#   Wir haben wie üblich nur einzelne Messpunkte. Wie gehen wir methodisch vor,
#   wenn daraus eine räumliche Aussagefläche entstehen soll?
#
# Die Studierenden trainieren hier nicht ein fertiges Mikroklimamodell, sondern
# den Umgang mit einem Basisskript. Das Skript wird geöffnet, blockweise gelesen
# und ausgeführt. Jeder Block beantwortet einen Teil der Einstiegsfrage:
# Welche Daten liegen vor? Welche Fläche ist überhaupt gestützt? Welche Annahme
# überträgt Punktwerte in den Raum? Und wie kritisch darf das Ergebnis gelesen
# werden?
#
# Technische Kette:
#
#   1. Messpunkte laden
#   2. Höhenraster laden
#   3. einen Temperaturzeitpunkt auswählen
#   4. Höhenwerte an den Stationen aus dem DEM extrahieren
#   5. den gültigen Ausgaberaum begrenzen
#   6. ein Vorhersagegrid aus dem DEM bauen
#   7. vier einfache Modellvarianten rechnen
#   8. die Modelle mit Leave-One-Out-Cross-Validation prüfen
#   9. RMSE berechnen
#  10. die Ergebnisraster mit gleicher Farbskala darstellen
#  11. die Ergebnisraster zusätzlich als Leaflet-Karte anzeigen
#
# Inhaltliche Leitidee:
#   Aus Punktmessungen entsteht nicht automatisch eine belastbare Fläche.
#   Dazwischen steht immer eine Modellannahme. Genau diese Modellannahme ist
#   der methodische Kern der Übung.
#
# Die vier Modellannahmen in diesem Skript:
#
#   Voronoi      : nächste Station gewinnt
#   IDW          : nahe Stationen zählen stärker als entfernte
#   LM altitude  : Temperatur wird über Höhe übertragen
#   RF warning   : Random Forest lernt Raum-/Höhenmuster aus wenigen Punkten
#
# Benötigte Dateien:
#
#   data/climdata.rds
#   data/DEM1.tif
#
# Benötigte Pakete:
#
#   sf
#   terra
#   gstat
#   randomForest
#   leaflet
#
# =============================================================================


# =============================================================================
# 1. DATEN LADEN
# =============================================================================
#
# sf:
#   verarbeitet Vektordaten, hier die Messstationen mit Geometrie.
#
# terra:
#   verarbeitet Rasterdaten, hier das digitale Höhenmodell.
#
# gstat:
#   liefert IDW, nearest-neighbour über nmax = 1 und gstat.cv().
#
# randomForest:
#   liefert das datengetriebene Vergleichsmodell.
#
# leaflet:
#   zeigt die Ergebnisraster am Ende zusätzlich als interaktive Karte.
#
# Keine weiteren Pakete werden benötigt.

library(sf)
library(terra)
library(gstat)
library(randomForest)
library(leaflet)


# Messstationen laden.
# Erwartung:
#   m ist ein sf-Objekt.
#   Es enthält Punktgeometrien und Temperaturspalten.
#
# Wichtig:
#   readRDS() liest ein fertiges R-Objekt.
#   Es findet hier kein Rohdatenimport statt.

m <- readRDS("data/climdata.rds")


# Digitales Höhenmodell laden.
# Erwartung:
#   DEM1.tif ist ein Raster.
#   Jede Rasterzelle enthält einen Höhenwert.

dem <- rast("data/DEM1.tif")


# Der Layername wird explizit gesetzt.
# Dadurch heißt die Höhenvariable später überall gleich: altitude.

names(dem) <- "altitude"


# =============================================================================
# 2. EINEN TEMPERATURZEITPUNKT AUSWÄHLEN
# =============================================================================
#
# Die Messdaten enthalten mehrere Temperaturspalten.
# Für den Warmup wird genau eine Spalte gewählt.
#
# Die fachliche Frage lautet hier nicht: Gibt es Mikroklima?
# Die Ausgangslage ist praktischer:
#   Wir haben einzelne Messpunkte und wollen daraus eine vorsichtige räumliche
#   Aussage ableiten.
#
# Vorteil:
#   Alle Modelle arbeiten mit derselben Zielvariable.
#   Unterschiede in den Ergebnissen kommen daher aus der Modellannahme,
#   nicht aus unterschiedlichen Zeitpunkten.

m$temp <- m[["A20230830"]]


# =============================================================================
# 3. KOORDINATENSYSTEM ANGLEICHEN
# =============================================================================
#
# Punktdaten und Raster müssen im selben Koordinatensystem liegen.
#
# Warum?
#   - Höhenextraktion funktioniert räumlich nur korrekt bei passendem CRS.
#   - Distanzen für IDW/Voronoi müssen im richtigen Raum berechnet werden.
#   - Rasterzellen und Messpunkte müssen deckungsgleich interpretierbar sein.
#
# Das DEM gibt hier das Ziel-CRS vor.

m <- st_transform(m, crs(dem))


# =============================================================================
# 4. HÖHE AN DEN STATIONEN EXTRAHIEREN
# =============================================================================
#
# Für jede Messstation wird der Höhenwert aus dem DEM gezogen.
#
# Warum nicht eine vorhandene Höhenvariable verwenden?
#   Weil Stationshöhe und Ergebnisraster dann aus derselben Höhenbasis stammen.
#   Das verhindert einen Bruch zwischen Punktdaten und Rastermodell.

m$altitude <- terra::extract(dem, terra::vect(m))$altitude


# =============================================================================
# 5. GÜLTIGE MESSPUNKTE AUSWÄHLEN
# =============================================================================
#
# Für die Modellierung braucht jede Station:
#
#   temp      : Temperatur am gewählten Zeitpunkt
#   altitude  : Höhe aus dem DEM
#
# Stationen mit fehlender Temperatur oder fehlender Höhe werden entfernt.

pts <- m[!is.na(m$temp) & !is.na(m$altitude), c("temp", "altitude")]


# =============================================================================
# 6. AUSSAGEFLÄCHE ERZEUGEN
# =============================================================================
#
# Interpolation soll nicht beliebig weit außerhalb des Messnetzes ausgegeben
# werden. Deshalb wird die räumliche Ausgabe auf den Stationsraum begrenzt.
#
# Arbeitsschritte:
#
#   st_geometry(pts)
#     nimmt nur die Punktgeometrien.
#
#   st_union(...)
#     fasst die Punkte geometrisch zusammen.
#
#   st_convex_hull(...)
#     bildet die konvexe Hülle um die Stationen.
#
#   st_buffer(..., 20)
#     erweitert diese Hülle um 20 m.
#
# Ergebnis:
#   area ist die gültige Aussagefläche für alle Ergebnisraster.

area <- st_sf(
  geometry = st_buffer(
    st_convex_hull(st_union(st_geometry(pts))),
    20
  )
)


# DEM auf die Aussagefläche zuschneiden.
# crop() reduziert zunächst den rechteckigen Ausschnitt.
# mask() setzt anschließend Zellen außerhalb der genauen Fläche auf NA.

dem <- crop(dem, vect(area))
dem <- mask(dem, vect(area))


# Der Name wird nach crop/mask erneut gesetzt.
# Das hält die spätere Tabellenstruktur stabil.

names(dem) <- "altitude"


# =============================================================================
# 7. VORHERSAGEGRID AUS DEM DEM BAUEN
# =============================================================================
#
# Die Modelle brauchen Zielorte, an denen Werte vorhergesagt werden.
# Diese Zielorte sind alle gültigen Rasterzellen innerhalb der Aussagefläche.
#
# as.data.frame(..., xy = TRUE, cells = TRUE):
#   erzeugt aus dem Raster eine Tabelle mit:
#
#   cell      : Zellnummer im Raster
#   x         : x-Koordinate der Rasterzelle
#   y         : y-Koordinate der Rasterzelle
#   altitude  : Höhenwert der Rasterzelle

grid <- as.data.frame(dem, xy = TRUE, cells = TRUE, na.rm = FALSE)


# Die vierte Spalte enthält die Höhenwerte.
# Sie wird explizit altitude genannt.

names(grid)[4] <- "altitude"


# Nur gültige Rasterzellen bleiben erhalten.
# Zellen außerhalb der Aussagefläche haben NA und werden entfernt.

grid <- grid[!is.na(grid$altitude), ]


# Für gstat müssen die Zielorte als Punktobjekt vorliegen.
#
# remove = FALSE:
#   x und y bleiben zusätzlich als normale Tabellenspalten erhalten.
#   Das ist später für Random Forest und die Kartendarstellung nützlich.

grid_sf <- st_as_sf(
  grid,
  coords = c("x", "y"),
  crs = st_crs(pts),
  remove = FALSE
)


# =============================================================================
# 8. HILFSFUNKTIONEN
# =============================================================================
#
# make_map():
#   Viele Modelle liefern eine Vorhersage pro gültiger Rasterzelle.
#   Diese Vorhersagen müssen wieder an die richtige Zellposition im Raster.
#
#   pred:
#     Vorhersagewerte in derselben Reihenfolge wie grid.
#
#   name:
#     Name des Ergebnisrasters.
#
#   r <- dem:
#     Das Ergebnisraster übernimmt Geometrie, Auflösung, Ausdehnung und Maske
#     vom vorbereiteten DEM.
#
#   values(r)[grid$cell] <- pred:
#     Die Vorhersagen werden in die passenden Rasterzellen geschrieben.

make_map <- function(pred, name) {
  r <- dem
  values(r) <- NA
  values(r)[grid$cell] <- pred
  names(r) <- name
  r
}


# rmse_fun():
#   berechnet den Root Mean Squared Error.
#
#   e:
#     Fehlervektor, also Messwert minus Vorhersage oder umgekehrt.
#
#   e * e:
#     quadriert die Fehler.
#
#   mean(...):
#     mittelt die quadrierten Fehler.
#
#   sqrt(...):
#     zieht die Wurzel.
#
# Interpretation:
#   kleiner RMSE = kleinere Rückschätzfehler an den Stationsorten.

rmse_fun <- function(e) {
  sqrt(mean(e * e, na.rm = TRUE))
}


# =============================================================================
# 9. KOORDINATEN FÜR RANDOM FOREST ERGÄNZEN
# =============================================================================
#
# Random Forest soll bewusst als Warnbeispiel mit Raumkoordinaten arbeiten.
# Deshalb werden x und y aus der Punktgeometrie als normale Spalten ergänzt.
#
# Fachlicher Punkt:
#   RF kann dann räumliche Lage direkt nutzen.
#   Bei wenigen Punkten kann das plausibel wirken, aber stark an die Punktlage
#   angepasst sein.

xy <- st_coordinates(pts)
pts$x <- xy[, 1]
pts$y <- xy[, 2]


# =============================================================================
# 10. MODELL 1: LM ALTITUDE
# =============================================================================
#
# Lineares Modell:
#
#   temp ~ altitude
#
# Bedeutung:
#   Temperatur wird als lineare Funktion der Höhe geschätzt.
#
# Modellannahme:
#   Höhe erklärt einen Teil der Temperaturunterschiede.
#
# Ergebnis:
#   Das Ergebnisraster folgt dem Höhenraster.

fit_lm <- lm(temp ~ altitude, data = st_drop_geometry(pts))


# predict(dem, fit_lm):
#   wendet das Höhenmodell auf jede gültige Rasterzelle des DEM an.
#
# Voraussetzung:
#   Das Raster enthält eine Variable mit exakt dem Namen altitude.

map_lm <- predict(dem, fit_lm)
names(map_lm) <- "LM_altitude"


# =============================================================================
# 11. MODELL 2: VORONOI / NEAREST STATION
# =============================================================================
#
# Voronoi wird hier als nearest-neighbour-Variante gerechnet.
#
# Technisch:
#   gstat::idw(..., nmax = 1)
#
# Bedeutung von nmax = 1:
#   Für jede Rasterzelle wird nur die nächste Station verwendet.
#
# Modellannahme:
#   Der nächstgelegene Messpunkt ist für die Zelle zuständig.
#
# Ergebnis:
#   harte Stationsbereiche ohne Glättung.

vor_df <- gstat::idw(
  temp ~ 1,
  locations = pts,
  newdata = grid_sf,
  nmax = 1
)


# Die Vorhersagen werden wieder in ein Raster geschrieben.

map_vor <- make_map(vor_df$var1.pred, "Voronoi")


# =============================================================================
# 12. MODELL 3: IDW
# =============================================================================
#
# IDW = inverse distance weighting.
#
# Grundidee:
#   Nahe Stationen zählen stärker als entfernte Stationen.
#
# Technische Einstellung:
#   nmax = 4
#
# Bedeutung:
#   Für jede Rasterzelle werden nur die vier nächsten Stationen verwendet.
#
# Modellannahme:
#   Temperatur wird lokal über räumliche Nähe übertragen.
#
# Ergebnis:
#   geglättetes, aber lokal begrenztes Ergebnisraster.

idw_df <- gstat::idw(
  temp ~ 1,
  locations = pts,
  newdata = grid_sf,
  nmax = 4
)


# Die IDW-Vorhersagen werden wieder in ein Raster geschrieben.

map_idw <- make_map(idw_df$var1.pred, "IDW")


# =============================================================================
# 13. MODELL 4: RANDOM FOREST WARNING
# =============================================================================
#
# Random Forest bekommt drei Prädiktoren:
#
#   x
#   y
#   altitude
#
# Bedeutung:
#   Das Modell darf räumliche Lage und Höhe datengetrieben kombinieren.
#
# Warum warning?
#   Bei wenigen Messpunkten kann RF scheinbar gute räumliche Muster erzeugen.
#   Diese Muster können aber stark aus der vorhandenen Punktverteilung stammen.
#
# Fachliche Pointe:
#   Niedriger Fehlerwert heißt nicht automatisch robuste Ergebnisfläche.

fit_rf <- randomForest(
  temp ~ x + y + altitude,
  data = st_drop_geometry(pts),
  ntree = 200
)


# Vorhersage für alle gültigen Rasterzellen im grid.
# grid enthält x, y und altitude und passt damit zu den RF-Prädiktoren.

rf_pred <- predict(fit_rf, newdata = grid)


# Die RF-Vorhersagen werden wieder in ein Raster geschrieben.

map_rf <- make_map(rf_pred, "RF_warning")


# =============================================================================
# 14. VALIDIERUNG: LEAVE-ONE-OUT-CROSS-VALIDATION
# =============================================================================
#
# Ziel:
#   Prüfen, wie gut die Modelle bekannte Stationen zurückschätzen.
#
# Prinzip:
#   Eine Station wird ausgelassen.
#   Das Modell wird mit den übrigen Stationen neu berechnet.
#   Die ausgelassene Station wird vorhergesagt.
#   Der Fehler wird gespeichert.
#
# Wichtig:
#   Das prüft Punktvorhersagen an Stationsorten.
#   Es beweist nicht automatisch die Qualität der ganzen Ergebnisfläche.


# -----------------------------------------------------------------------------
# 14a. LOOCV für LM und RF
# -----------------------------------------------------------------------------
#
# Für LM und RF wird die Leave-One-Out-Logik explizit ausgeschrieben.
# Das ist didaktisch klarer als eine versteckte Spezialfunktion.

lm_cv <- rep(NA, nrow(pts))
rf_cv <- rep(NA, nrow(pts))


# Schleife über alle Stationen.
# i ist jeweils die Station, die ausgelassen wird.

for (i in 1:nrow(pts)) {
  
  # Trainingsdaten:
  # alle Stationen außer Station i.
  train <- pts[-i, ]
  
  # Testdaten:
  # nur Station i.
  test <- pts[i, ]
  
  # LM ohne die ausgelassene Station neu berechnen.
  fit_lm_i <- lm(temp ~ altitude, data = st_drop_geometry(train))
  
  # Temperatur an der ausgelassenen Station mit dem LM vorhersagen.
  lm_cv[i] <- predict(fit_lm_i, newdata = st_drop_geometry(test))
  
  # RF ohne die ausgelassene Station neu berechnen.
  fit_rf_i <- randomForest(
    temp ~ x + y + altitude,
    data = st_drop_geometry(train),
    ntree = 200
  )
  
  # Temperatur an der ausgelassenen Station mit RF vorhersagen.
  rf_cv[i] <- predict(fit_rf_i, newdata = st_drop_geometry(test))
}


# -----------------------------------------------------------------------------
# 14b. LOOCV für Voronoi und IDW
# -----------------------------------------------------------------------------
#
# gstat.cv() übernimmt die Leave-One-Out-Prüfung für gstat-Modelle.
#
# Entscheidend:
#   Die Validierung muss dieselbe Nachbarschaft verwenden wie die
#   Ergebnisberechnung.
#
#   Voronoi:
#     nmax = 1
#
#   IDW:
#     nmax = 4

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


# -----------------------------------------------------------------------------
# 14c. RMSE-Tabelle
# -----------------------------------------------------------------------------
#
# Für jedes Modell wird ein RMSE berechnet.
#
# Interpretation:
#   kleiner RMSE = bessere Rückschätzung der ausgelassenen Stationen.
#
# Grenze:
#   Der RMSE allein sagt nicht, ob das räumliche Ergebnis fachlich plausibel ist.

rmse <- data.frame(
  model = c("LM altitude", "Voronoi", "IDW", "RF warning"),
  RMSE = c(
    rmse_fun(pts$temp - lm_cv),
    rmse_fun(vor_cv$residual),
    rmse_fun(idw_cv$residual),
    rmse_fun(pts$temp - rf_cv)
  )
)


# =============================================================================
# 15. ERGEBNISRASTER STATISCH DARSTELLEN
# =============================================================================
#
# Die vier Ergebnisraster werden zunächst als einfache Plots gemeinsam
# dargestellt.
#
# Wichtig:
#   Alle verwenden dieselbe Farbskala.
#   Dadurch sind die räumlichen Muster vergleichbar.
#
# Die Messpunkte werden überlagert.
# So sieht man, welche Ergebnisstruktur durch welche Stationslage gestützt wird.

maps <- c(map_vor, map_idw, map_lm, map_rf)


# Gemeinsamer Farbbereich:
#   beobachtete Temperaturwerte minus/plus 1 Grad.
#
# Das verhindert, dass jedes Panel durch eigene Skalierung künstlich
# plausibel oder dramatisch wirkt.

z <- range(c(pts$temp - 1, pts$temp + 1), na.rm = TRUE)


# 2 x 2 Panel für die vier Ergebnisraster.

par(mfrow = c(2, 2))


# Jedes Raster wird geplottet.
# Danach werden die Messstationen als schwarze Punkte ergänzt.

for (i in 1:nlyr(maps)) {
  plot(maps[[i]], range = z, main = names(maps)[i])
  points(pts, pch = 19, cex = 0.8)
}


# Plotlayout zurücksetzen.

par(mfrow = c(1, 1))


# RMSE-Tabelle ausgeben.
# Diese Tabelle ist der Einstieg in die Modellkritik.

print(rmse)

# =============================================================================
# 16. ERGEBNISRASTER ALS LEAFLET-KARTE DARSTELLEN
# =============================================================================
#
# Die statischen Plots zeigen den direkten Modellvergleich.
# Zusätzlich werden dieselben Ergebnisraster in einer interaktiven Leaflet-Karte
# angezeigt.
#
# Warum zusätzlich Leaflet?
#   Die Karte macht die räumliche Aussagefläche, die Messpunkte und die vier
#   Modellannahmen noch einmal gemeinsam lesbar. Damit wird die Einstiegsfrage
#   wieder aufgegriffen: Wie gehen wir vor, wenn wir nur Punkte haben, aber eine
#   räumliche Aussage treffen wollen?
#
# Wichtig:
#   Leaflet ist hier nur Darstellung.
#   Es rechnet kein neues Modell und verändert keine Ergebniswerte.
#   Die angezeigten Layer sind dieselben Raster wie in den statischen Plots.

pts_ll  <- st_transform(pts, 4326)
area_ll <- st_transform(area, 4326)

pal <- colorNumeric(
  palette = "RdYlBu",
  domain = z,
  reverse = TRUE,
  na.color = "transparent"
)

leaflet_map <- leaflet() |>
  addProviderTiles(providers$CartoDB.Positron, group = "Hintergrund") |>
  addPolygons(
    data = area_ll,
    group = "Aussagefläche",
    color = "black",
    weight = 2,
    fill = FALSE
  )

for (i in 1:nlyr(maps)) {
  leaflet_map <- leaflet_map |>
    addRasterImage(
      x = maps[[i]],
      colors = pal,
      opacity = 0.75,
      group = names(maps)[i],
      project = TRUE
    )
}

leaflet_map <- leaflet_map |>
  addCircleMarkers(
    data = pts_ll,
    group = "Messpunkte",
    radius = 5,
    stroke = TRUE,
    weight = 1,
    color = "black",
    fillColor = ~pal(temp),
    fillOpacity = 1,
    label = ~paste0("Messwert: ", round(temp, 2), " °C")
  ) |>
  addLegend(
    pal = pal,
    values = z,
    title = "Temperatur",
    opacity = 1
  ) |>
  addLayersControl(
    baseGroups = names(maps),
    overlayGroups = c("Messpunkte", "Aussagefläche"),
    options = layersControlOptions(collapsed = FALSE)
  ) |>
  hideGroup(names(maps)[-1])

leaflet_map



# =============================================================================
# ENDE
# =============================================================================
#
# Leselogik der Ergebnisse:
#
#   Voronoi:
#     harte Stationsbereiche
#
#   IDW:
#     lokale Nachbarschaft
#
#   LM altitude:
#     Höhenzusammenhang
#
#   RF warning:
#     datengetriebene Raum-/Höhenpartition
#
# Zentrale Schlussfolgerung:
#   Wenn nur Punktmessungen vorliegen, ist der Weg zur Fläche kein technischer
#   Automatismus. Er besteht aus Datenprüfung, Begrenzung der Aussagefläche,
#   Wahl einer Modellannahme, Validierung und kritischer Kartenlektüre.
#
#   Ein räumliches Ergebnis aus Punktmessungen ist immer eine modellierte
#   Aussage. Es muss zur Datenlage, zur Aussagefläche und zur fachlichen
#   Modellannahme passen.
# =============================================================================
