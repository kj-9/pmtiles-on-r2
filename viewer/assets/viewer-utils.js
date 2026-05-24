(function () {
  const osmSource = {
    type: "raster",
    tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
    tileSize: 256,
    attribution: "© OpenStreetMap contributors",
  };

  function createRasterMap(options = {}) {
    return new maplibregl.Map({
      container: options.container || "map",
      style: {
        version: 8,
        sources: {
          [options.basemapSourceId || "osm"]: osmSource,
        },
        layers: [
          {
            id: options.basemapLayerId || "osm",
            type: "raster",
            source: options.basemapSourceId || "osm",
          },
        ],
      },
      center: options.center || [139.767, 35.681],
      zoom: options.zoom || 10,
      maxZoom: options.maxZoom || 17,
    });
  }

  function registerPmtilesProtocol() {
    const protocol = new pmtiles.Protocol();
    maplibregl.addProtocol("pmtiles", protocol.tile);
    return protocol;
  }

  function removeLayerAndSource(map, layerId, sourceId) {
    if (map.getLayer(layerId)) map.removeLayer(layerId);
    if (map.getSource(sourceId)) map.removeSource(sourceId);
  }

  function boundsFromHeader(header) {
    return Array.isArray(header.bounds) && header.bounds.length === 4
      ? [
          [header.bounds[0], header.bounds[1]],
          [header.bounds[2], header.bounds[3]],
        ]
      : null;
  }

  function centerFromHeader(header, map) {
    const bounds = boundsFromHeader(header);
    const center = header.center;
    if (Array.isArray(center) && center.length >= 2) {
      return {
        center: [center[0], center[1]],
        zoom: center.length >= 3 ? center[2] : map.getZoom(),
      };
    }
    if (!bounds) return { center: map.getCenter().toArray(), zoom: map.getZoom() };
    return {
      center: [
        (bounds[0][0] + bounds[1][0]) / 2,
        (bounds[0][1] + bounds[1][1]) / 2,
      ],
      zoom: map.getZoom(),
    };
  }

  function fitPmtilesHeader(map, header, options = {}) {
    const bounds = boundsFromHeader(header);
    if (bounds) {
      map.fitBounds(bounds, {
        padding: options.padding || 40,
        maxZoom: options.maxZoom || map.getMaxZoom(),
      });
      return;
    }

    const target = centerFromHeader(header, map);
    map.setCenter(target.center);
    if (target.zoom) map.setZoom(target.zoom);
  }

  async function addPmtilesRasterLayer(map, protocol, options) {
    removeLayerAndSource(map, options.layerId, options.sourceId);

    const resolvedUrl = new URL(options.url, location.href).href;
    const archive = new pmtiles.PMTiles(resolvedUrl);
    protocol.add(archive);
    const header = await archive.getHeader();

    map.addSource(options.sourceId, {
      type: "raster",
      url: `pmtiles://${resolvedUrl}`,
      tileSize: options.tileSize || 256,
    });
    map.addLayer({
      id: options.layerId,
      type: "raster",
      source: options.sourceId,
      paint: options.paint || {},
    });

    if (options.fit !== false) {
      fitPmtilesHeader(map, header, options.fitOptions || {});
    }

    return { archive, header, url: resolvedUrl };
  }

  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return "-";
    const units = ["B", "KB", "MB", "GB"];
    let value = bytes;
    let unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    return `${value.toFixed(value >= 10 ? 1 : 2)} ${units[unitIndex]}`;
  }

  window.Viewer = {
    addPmtilesRasterLayer,
    createRasterMap,
    fitPmtilesHeader,
    formatBytes,
    registerPmtilesProtocol,
    removeLayerAndSource,
  };
})();
