//
//  OAMapillaryTilesProvider.m
//  OsmAnd
//
//  Created by Alexey on 19/05/2019.
//  Copyright © 2019 OsmAnd. All rights reserved.
//

#include "OAMapillaryTilesProvider.h"
#import "OANativeUtilities.h"
#import "OAAppSettings.h"
#import "OAColors.h"
#import "OAWebClient.h"
#import "OAMapillaryImage.h"

#include <OsmAndCore/Map/MapDataProviderHelpers.h>
#include <OsmAndCore/Data/Amenity.h>
#include <OsmAndCore/Utilities.h>
#include <OsmAndCore/SkiaUtilities.h>
#include <OsmAndCore/Logging.h>
#include <QStandardPaths>
#include <OsmAndCore/LatLon.h>
#include <OsmAndCore/IWebClient.h>
#include <OsmAndCore/ResourcesManager.h>
#include <OsmAndCore/IQueryController.h>
#include "OAWebClient.h"
#include <SkImageEncoder.h>
#include <SkCanvas.h>
#include <SkBitmap.h>
#include <SkImage.h>
#include <SkData.h>
#include <SkPaint.h>

#define EXTENT 4096.0
#define LINE_WIDTH 3.0f

#define MAX_SEQUENCE_LAYER_ZOOM 13

OAMapillaryTilesProvider::OAMapillaryTilesProvider(const float displayDensityFactor /* = 1.0f*/, const unsigned long long physicalMemory /*= 0*/)
: _vectorName(QStringLiteral("mapillary_vector"))
, _vectorPathSuffix(QString(_vectorName).replace(QRegExp(QLatin1String("\\W+")), QLatin1String("_")))
, _vectorUrlPattern(QStringLiteral("https://tiles.mapillary.com/maps/vtp/mly1_public/2/${osm_zoom}/${osm_x}/${osm_y}/?access_token=") + QString::fromNSString(MAPILLARY_ACCESS_TOKEN))
, _vectorZoomLevel(OsmAnd::ZoomLevel14)
, _webClient(std::shared_ptr<const OsmAnd::IWebClient>(new OAWebClient()))
, _networkAccessAllowed(true)
, _displayDensityFactor(displayDensityFactor)
, _physicalMemory(physicalMemory)
, _mvtReader(new OsmAnd::MvtReader())
, _image([OANativeUtilities skImageFromPngResource:@"map_mapillary_photo_dot"])
, _linePaint(new SkPaint())
{
    if (physicalMemory > (unsigned long long) 2 << 30)
        _maxCacheSize = 5;
    else if (physicalMemory > (unsigned long long) 1 << 30)
        _maxCacheSize = 4;
    else
        _maxCacheSize = 3;

    _vectorLocalCachePath = QDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation)).absoluteFilePath(_vectorPathSuffix);
    if (_vectorLocalCachePath.isEmpty())
        _vectorLocalCachePath = QLatin1String(".");
    
    _linePaint->setColor(OsmAnd::ColorARGB(color_mapillary).toSkColor());
    _linePaint->setStrokeWidth(LINE_WIDTH * _displayDensityFactor);
    _linePaint->setAntiAlias(true);
    _linePaint->setStrokeJoin(SkPaint::kRound_Join);
    _linePaint->setStrokeCap(SkPaint::kRound_Cap);
}

OAMapillaryTilesProvider::~OAMapillaryTilesProvider()
{
}

OsmAnd::AlphaChannelPresence OAMapillaryTilesProvider::getAlphaChannelPresence() const
{
    return OsmAnd::AlphaChannelPresence::Present;
}

OsmAnd::ZoomLevel OAMapillaryTilesProvider::getZoomForRequest(const OsmAnd::IMapTiledDataProvider::Request &req)
{
    OsmAnd::ZoomLevel zoom;
    if (req.zoom < getPointsZoom())
        zoom = OsmAnd::ZoomLevel(MAX_SEQUENCE_LAYER_ZOOM);
    else
        zoom = _vectorZoomLevel;
    return zoom;
}

void OAMapillaryTilesProvider::drawPoints(
                                          const OsmAnd::IMapTiledDataProvider::Request &req,
                                          const OsmAnd::TileId &tileId,
                                          const std::shared_ptr<const OsmAnd::MvtReader::Tile>& geometryTile,
                                          SkCanvas& canvas)
{
    if (!_image)
        return;

    int dzoom = req.zoom - getZoomForRequest(req);
    double mult = (int) pow(2.0, dzoom);
    const auto tileSize31 = (1u << (OsmAnd::ZoomLevel::MaxZoomLevel - req.zoom));
    const auto zoomShift = OsmAnd::ZoomLevel::MaxZoomLevel - req.zoom;
    const auto tileBBox31 = OsmAnd::Utilities::tileBoundingBox31(req.tileId, req.zoom);
    const auto tileSize = getTileSize();
    const auto px31Size = tileSize31 / tileSize;
    const auto bitmapHalfSize = _image->width() / 2;
    const auto& tileBBox31Enlarged = OsmAnd::Utilities::tileBoundingBox31(req.tileId, req.zoom).enlargeBy(bitmapHalfSize * px31Size);
    
    for (const auto& point : geometryTile->getGeometry())
    {
        if (point == nullptr || point->getType() != OsmAnd::MvtReader::GeomType::POINT)
            continue;
        
        double px, py;
        const auto& p = std::dynamic_pointer_cast<const OsmAnd::MvtReader::Point>(point);
        OsmAnd::PointI coordinate = p->getCoordinate();
        px = coordinate.x / EXTENT;
        py = coordinate.y / EXTENT;
        
        double tileX = ((tileId.x << zoomShift) + (tileSize31 * px)) * mult;
        double tileY = ((tileId.y << zoomShift) + (tileSize31 * py)) * mult;
        
        if (tileBBox31Enlarged.contains(tileX, tileY)) {
            if ([OAAppSettings sharedManager].useMapillaryFilter.get && filtered(p->getUserData(), geometryTile))
                    continue;
            
            SkScalar x = ((tileX - tileBBox31.left()) / tileSize31) * tileSize - bitmapHalfSize;
            SkScalar y = ((tileY - tileBBox31.top()) / tileSize31) * tileSize - bitmapHalfSize;
            canvas.drawImage(_image, x, y);
        }
    }
}

bool OAMapillaryTilesProvider::filtered(const QHash<uint8_t, QVariant> &userData, const std::shared_ptr<const OsmAnd::MvtReader::Tile>& geometryTile) const
{
    if (userData.count() == 0)
        return true;

    OAAppSettings *settings = [OAAppSettings sharedManager];
    QString keys = QString::fromNSString(settings.mapillaryFilterUserKey.get);
    QStringList userKeys = keys.split(QStringLiteral("$$$"));
    double capturedAt = userData[OsmAnd::MvtReader::getUserDataId(kCapturedAtKey)].toDouble() / 1000;
    double from = settings.mapillaryFilterStartDate.get;
    double to = settings.mapillaryFilterEndDate.get;
    bool pano = settings.mapillaryFilterPano.get;
    
    if (userKeys.count() > 0 && (keys.compare(QStringLiteral("")) != 0))
    {
        const auto keyId = userData[OsmAnd::MvtReader::getUserDataId(kOrganizationIdKey)].toInt();
        const auto& key = geometryTile->getUserKey(keyId);
        if (!userKeys.contains(key))
            return true;
    }
    if (from != 0 && to != 0)
    {
        if (capturedAt < from || capturedAt > to)
            return true;
    }
    else if ((from != 0 && capturedAt < from) || (to != 0 && capturedAt > to))
        return true;
    if (pano)
        return userData[OsmAnd::MvtReader::getUserDataId(kIsPanoramiceKey)].toInt() == 0;

    return false;
}

void OAMapillaryTilesProvider::drawLine(
                                        const std::shared_ptr<const OsmAnd::MvtReader::LineString> &line,
                                        const OsmAnd::IMapTiledDataProvider::Request &req,
                                        const OsmAnd::TileId &tileId,
                                        SkCanvas& canvas)
{
    if (line->getCoordinateSequence().isEmpty())
        return;
    
    int dzoom = req.zoom - getZoomForRequest(req);
    int mult = (int) pow(2.0, dzoom);
    double px, py;
    const auto &linePts = line->getCoordinateSequence();
    const auto tileSize31 = (1u << (OsmAnd::ZoomLevel::MaxZoomLevel - req.zoom));
    const auto zoomShift = OsmAnd::ZoomLevel::MaxZoomLevel - req.zoom;
    const auto tileBBox31 = OsmAnd::Utilities::tileBoundingBox31(req.tileId, req.zoom);
    const auto tileSize = getTileSize();
    const auto px31Size = tileSize31 / tileSize;
    const auto bitmapHalfSize = tileSize / 2;
    const auto& tileBBox31Enlarged = OsmAnd::Utilities::tileBoundingBox31(req.tileId, req.zoom).enlargeBy(bitmapHalfSize * px31Size);
    
    SkScalar x1, y1, x2, y2 = 0;
    
    double lastTileX, lastTileY;
    const auto& firstPnt = linePts[0];
    px = firstPnt.x / EXTENT;
    py = firstPnt.y / EXTENT;
    lastTileX = ((tileId.x << zoomShift) + (tileSize31 * px)) * mult;
    lastTileY = ((tileId.y << zoomShift) + (tileSize31 * py)) * mult;
    x1 = ((lastTileX - tileBBox31.left()) / tileSize31) * tileSize;
    y1 = ((lastTileY - tileBBox31.top()) / tileSize31) * tileSize;
    
    bool recalculateLastXY = false;
    for (int i = 1; i < linePts.size(); i++)
    {
        const auto& point = linePts[i];
        px = point.x / EXTENT;
        py = point.y / EXTENT;
        
        double tileX = ((tileId.x << zoomShift) + (tileSize31 * px)) * mult;
        double tileY = ((tileId.y << zoomShift) + (tileSize31 * py)) * mult;

        if (tileBBox31Enlarged.contains(tileX, tileY))
        {
            x2 = ((tileX - tileBBox31.left()) / tileSize31) * tileSize;
            y2 = ((tileY - tileBBox31.top()) / tileSize31) * tileSize;
            
            if (recalculateLastXY)
            {
                x1 = ((lastTileX - tileBBox31.left()) / tileSize31) * tileSize;
                y1 = ((lastTileY - tileBBox31.top()) / tileSize31) * tileSize;
                recalculateLastXY = false;
            }
            canvas.drawLine(x1, y1, x2, y2, *_linePaint);
            
            x1 = x2;
            y1 = y2;
        }
        else
        {
            recalculateLastXY = true;
        }
        lastTileX = tileX;
        lastTileY = tileY;
    }
}

void OAMapillaryTilesProvider::drawLines(
                                         const OsmAnd::IMapTiledDataProvider::Request &req,
                                         const OsmAnd::TileId &tileId,
                                         const std::shared_ptr<const OsmAnd::MvtReader::Tile>& geometryTile,
                                         SkCanvas& canvas)
{
    for (const auto& point : geometryTile->getGeometry())
    {
        if (point == nullptr || (point->getType() != OsmAnd::MvtReader::GeomType::LINE_STRING && point->getType() != OsmAnd::MvtReader::GeomType::MULTI_LINE_STRING))
            continue;
        
        if (point->getType() == OsmAnd::MvtReader::GeomType::LINE_STRING)
        {
            const auto& line = std::dynamic_pointer_cast<const OsmAnd::MvtReader::LineString>(point);
            if (!filtered(line->getUserData(), geometryTile))
                drawLine(line, req, tileId, canvas);
        }
        else
        {
            const auto& multiline = std::dynamic_pointer_cast<const OsmAnd::MvtReader::MultiLineString>(point);
            if (!filtered(multiline->getUserData(), geometryTile))
                for (const auto &lineString : multiline->getLines())
                    drawLine(lineString, req, tileId, canvas);
        }
    }
}

void OAMapillaryTilesProvider::clearDiskCache(bool vectorRasterOnly/* = false*/)
{
    QString vectorLocalCachePath;
    {
        QMutexLocker scopedLocker(&_localCachePathMutex);
        
        vectorLocalCachePath = QString(_vectorLocalCachePath);
    }
    
    if (vectorLocalCachePath.isEmpty())
        return;

    QWriteLocker scopedLocker(&_localCacheLock);

    if (!vectorRasterOnly)
        QDir(vectorLocalCachePath).removeRecursively();

    QDir(vectorLocalCachePath + QDir::separator() + QLatin1String("png")).removeRecursively();
}

void OAMapillaryTilesProvider::clearMemoryCache(const bool clearAll /*= false*/)
{
    QMutexLocker scopedLocker(&_geometryCacheMutex);

    clearMemoryCacheImpl(clearAll);
}

void OAMapillaryTilesProvider::clearMemoryCacheImpl(const bool clearAll /*= false*/)
{
    if (clearAll) {
        _geometryCache.clear();
    }
    else
    {
        auto it = _geometryCache.begin();
        auto i = _geometryCache.size() / 2;
        while (it != _geometryCache.end() && i > 0) {
            it = _geometryCache.erase(it);
            i--;
        }
    }
}

std::shared_ptr<const OsmAnd::MvtReader::Tile> OAMapillaryTilesProvider::readGeometry(
                                                                                      const QFileInfo &localFile,
                                                                                      const OsmAnd::TileId &tileId)
{
    QMutexLocker scopedLocker(&_geometryCacheMutex);
    
    auto it = _geometryCache.constFind(tileId);
    if (it == _geometryCache.cend())
        it = _geometryCache.insert(tileId, _mvtReader->parseTile(localFile.absoluteFilePath()));
    
    const auto list = *it;
    
    if (_geometryCache.size() > _maxCacheSize)
        clearMemoryCacheImpl();
    
    return list;
}

std::shared_ptr<const OsmAnd::MvtReader::Tile> OAMapillaryTilesProvider::readGeometry(const OsmAnd::TileId &tileId)
{
    QReadLocker scopedLocker(&_localCacheLock);

    const auto tileLocalRelativePath =
    QString::number(_vectorZoomLevel) + QDir::separator() +
    QString::number(tileId.x) + QDir::separator() +
    QString::number(tileId.y) + QLatin1String(".mvt");
    
    QFileInfo localFile;
    {
        QMutexLocker scopedLocker(&_localCachePathMutex);
        localFile.setFile(QDir(_vectorLocalCachePath).absoluteFilePath(tileLocalRelativePath));
    }
    return localFile.exists() ? readGeometry(localFile, tileId) : nullptr;
}

bool OAMapillaryTilesProvider::drawTile(const std::shared_ptr<const OsmAnd::MvtReader::Tile>& geometryTile,
                                        const OsmAnd::TileId &tileId,
                                        const OsmAnd::IMapTiledDataProvider::Request &req,
                                        QByteArray& rawData,
                                        QByteArray& compressedData,
                                        int& width, int& height)
{
    if (req.queryController && req.queryController->isAborted())
        return false;

    SkBitmap bitmap;
    const auto tileSize = getTileSize();
    // Create a bitmap that will be hold entire symbol (if target is empty)
    if (!bitmap.tryAllocPixels(SkImageInfo::MakeN32Premul(tileSize, tileSize)))
    {
        LogPrintf(OsmAnd::LogSeverityLevel::Error,
                  "Failed to allocate bitmap of size %dx%d",
                  tileSize,
                  tileSize);
        return false;
    }
    
    bitmap.eraseColor(SK_ColorTRANSPARENT);
    
    SkCanvas canvas(bitmap);
    
    drawLines(req, tileId, geometryTile, canvas);
    if (req.zoom >= getPointsZoom())
        drawPoints(req, tileId, geometryTile, canvas);
    
    canvas.flush();
    
    const auto data = bitmap.asImage()->encodeToData(SkEncodedImageFormat::kPNG, 100);
    if (!data)
    {
        LogPrintf(OsmAnd::LogSeverityLevel::Error,
                  "Failed to encode bitmap of size %dx%d",
                  tileSize,
                  tileSize);
        return false;
    }
    rawData = QByteArray(reinterpret_cast<const char *>(bitmap.getPixels()), (int) bitmap.computeByteSize());
    compressedData = QByteArray(reinterpret_cast<const char *>(data->bytes()), (int) data->size());
    return true;
}

bool OAMapillaryTilesProvider::supportsObtainImage() const
{
    return true;
}

long long OAMapillaryTilesProvider::obtainImageData(const OsmAnd::ImageMapLayerProvider::Request& req, QByteArray& byteArray)
{
    return 0;
}

sk_sp<const SkImage> OAMapillaryTilesProvider::obtainImage(const OsmAnd::IMapTiledDataProvider::Request& req)
{
    // Check provider can supply this zoom level
    if (req.zoom > getMaxZoom() || req.zoom < getMinZoom())
        return nullptr;

    return getVectorTileImage(req);
}

sk_sp<const SkImage> OAMapillaryTilesProvider::getVectorTileImage(const OsmAnd::IMapTiledDataProvider::Request& req)
{
    QReadLocker scopedLocker(&_localCacheLock);

    const unsigned int absZoomShift = req.zoom - getZoomForRequest(req);
    const auto tileId = OsmAnd::Utilities::getTileIdOverscaledByZoomShift(req.tileId, absZoomShift);
    //const auto tileIds = OsmAnd::Utilities::getTileIdsUnderscaledByZoomShift(req.tileId, absZoomShift);
    // Check if requested tile is already being processed, and wait until that's done
    // to mark that as being processed.
    lockTile(req.tileId, req.zoom);

    const auto rasterTileRelativePath =
    QLatin1String("png") +  QDir::separator() +
    QString::number(req.zoom) + QDir::separator() +
    QString::number(req.tileId.x) + QDir::separator() +
    QString::number(req.tileId.y) + QLatin1String(".png");
    
    QFileInfo rasterFile;
    {
        QMutexLocker scopedLocker(&_localCachePathMutex);
        rasterFile.setFile(QDir(_vectorLocalCachePath).absoluteFilePath(rasterTileRelativePath));
    }
    if (rasterFile.exists())
    {
        unlockTile(req.tileId, req.zoom);

        if (rasterFile.size() == 0)
            return nullptr;

        QFile tileFile(rasterFile.absoluteFilePath());
        if (tileFile.open(QIODevice::ReadOnly))
        {
            const auto& data = tileFile.readAll();
            tileFile.close();
            return OsmAnd::SkiaUtilities::createImageFromData(data);
        }
        return nullptr;
    }
    
    QMutexLocker vectorTileLocker(&_vectorTileMutex);

    if (req.queryController && req.queryController->isAborted()) {
        unlockTile(req.tileId, req.zoom);
        return nullptr;
    }
    if (rasterFile.exists())
    {
        unlockTile(req.tileId, req.zoom);

        if (rasterFile.size() == 0)
            return nullptr;

        QFile tileFile(rasterFile.absoluteFilePath());
        if (tileFile.open(QIODevice::ReadOnly))
        {
            const auto& data = tileFile.readAll();
            tileFile.close();
            return OsmAnd::SkiaUtilities::createImageFromData(data);
        }
        return nullptr;
    }
    
    // Check if requested tile is already in local storage.
    const auto tileLocalRelativePath =
    QString::number(getZoomForRequest(req)) + QDir::separator() +
    QString::number(tileId.x) + QDir::separator() +
    QString::number(tileId.y) + QLatin1String(".mvt");
    
    QFileInfo localFile;
    {
        QMutexLocker scopedLocker(&_localCachePathMutex);
        localFile.setFile(QDir(_vectorLocalCachePath).absoluteFilePath(tileLocalRelativePath));
    }
    if (localFile.exists())
    {
        // If local file is empty, it means that requested tile does not exist (has no data)
        if (localFile.size() == 0)
        {
            unlockTile(req.tileId, req.zoom);
            return nullptr;
        }
        
        const auto& geometryTile = readGeometry(localFile, tileId);

        QByteArray rawData = QByteArray();
        QByteArray compressedData = QByteArray();
        int width = 0;
        int height = 0;
        bool hasData = !geometryTile->empty() ? drawTile(geometryTile, tileId, req, rawData, compressedData, width, height) : false;
        if (hasData)
        {
            QFile tileFile(rasterFile.absoluteFilePath());
            // Ensure that all directories are created in path to local tile
            rasterFile.dir().mkpath(QLatin1String("."));
            if (tileFile.open(QIODevice::WriteOnly | QIODevice::Truncate))
            {
                tileFile.write(compressedData);
                tileFile.close();
                
                LogPrintf(OsmAnd::LogSeverityLevel::Debug,
                          "Saved mapillary png tile to %s",
                          qPrintable(rasterFile.absoluteFilePath()));
            }
            else
            {
                LogPrintf(OsmAnd::LogSeverityLevel::Error,
                          "Failed to save mapillary png tile to '%s'",
                          qPrintable(rasterFile.absoluteFilePath()));
            }
        }
        // Unlock tile, since local storage work is done
        unlockTile(req.tileId, req.zoom);

        if (!rawData.isEmpty())
            return OsmAnd::SkiaUtilities::createSkImageARGB888With(rawData, width, height);
        else
            return nullptr;
    }
    
    // Since tile is not in local cache (or cache is disabled, which is the same),
    // the tile must be downloaded from network:
    
    // If network access is disallowed, return failure
    if (!_networkAccessAllowed)
    {
        // Before returning, unlock tile
        unlockTile(req.tileId, req.zoom);
        return nullptr;
    }
    
    // Perform synchronous download
    const auto tileUrl = QString(_vectorUrlPattern)
    .replace(QLatin1String("${osm_zoom}"), QString::number(getZoomForRequest(req)))
    .replace(QLatin1String("${osm_x}"), QString::number(tileId.x))
    .replace(QLatin1String("${osm_y}"), QString::number(tileId.y));
    
    OsmAnd::IWebClient::DataRequest dataRequest;
    dataRequest.queryController = req.queryController;
    const auto& downloadResult = _webClient->downloadData(tileUrl, dataRequest);
    
    // Ensure that all directories are created in path to local tile
    localFile.dir().mkpath(QLatin1String("."));
    
    // If there was error, check what the error was
    if (!dataRequest.requestResult || !dataRequest.requestResult->isSuccessful() || downloadResult.isEmpty())
    {
        if (dataRequest.requestResult)
        {
            const auto httpStatus = std::dynamic_pointer_cast<const OsmAnd::IWebClient::IHttpRequestResult>(dataRequest.requestResult)->getHttpStatusCode();
            
            LogPrintf(OsmAnd::LogSeverityLevel::Warning,
                      "Failed to download tile from %s (HTTP status %d)",
                      qPrintable(tileUrl),
                      httpStatus);
            
            // 404 means that this tile does not exist, so create a zero file
            if (httpStatus == 404)
            {
                // Save to a file
                QFile tileFile(localFile.absoluteFilePath());
                if (tileFile.open(QIODevice::WriteOnly | QIODevice::Truncate))
                {
                    tileFile.close();
                    
                    // Unlock the tile
                    unlockTile(req.tileId, req.zoom);
                    return nullptr;
                }
                else
                {
                    LogPrintf(OsmAnd::LogSeverityLevel::Error,
                              "Failed to mark tile as non-existent with empty file '%s'",
                              qPrintable(localFile.absoluteFilePath()));
                    
                    // Unlock the tile
                    unlockTile(req.tileId, req.zoom);
                    return nullptr;
                }
            }
        }
        // Unlock the tile
        unlockTile(req.tileId, req.zoom);
        return nullptr;
    }
    
    // Obtain all data
    LogPrintf(OsmAnd::LogSeverityLevel::Debug,
              "Downloaded tile from %s",
              qPrintable(tileUrl));
    
    // Save to a file
    QFile tileFile(localFile.absoluteFilePath());
    if (tileFile.open(QIODevice::WriteOnly | QIODevice::Truncate))
    {
        tileFile.write(downloadResult);
        tileFile.close();
        
        LogPrintf(OsmAnd::LogSeverityLevel::Debug,
                  "Saved tile from %s to %s",
                  qPrintable(tileUrl),
                  qPrintable(localFile.absoluteFilePath()));
    }
    else
    {
        LogPrintf(OsmAnd::LogSeverityLevel::Error,
                  "Failed to save tile to '%s'",
                  qPrintable(localFile.absoluteFilePath()));
    }
        
    const auto& geometryTile = readGeometry(localFile, tileId);

    QByteArray rawData = QByteArray();
    QByteArray compressedData = QByteArray();
    int width = 0;
    int height = 0;
    bool hasData = drawTile(geometryTile, tileId, req, rawData, compressedData, width, height);
    if (hasData)
    {
        QFile tileFile(rasterFile.absoluteFilePath());
        // Ensure that all directories are created in path to local tile
        rasterFile.dir().mkpath(QLatin1String("."));
        if (tileFile.open(QIODevice::WriteOnly | QIODevice::Truncate))
        {
            tileFile.write(compressedData);
            tileFile.close();
            
            LogPrintf(OsmAnd::LogSeverityLevel::Debug,
                      "Saved mapillary png tile to %s",
                      qPrintable(rasterFile.absoluteFilePath()));
        }
        else
        {
            LogPrintf(OsmAnd::LogSeverityLevel::Error,
                      "Failed to save mapillary png tile to '%s'",
                      qPrintable(rasterFile.absoluteFilePath()));
        }
    }
    // Unlock tile, since local storage work is done
    unlockTile(req.tileId, req.zoom);

    if (!rawData.isEmpty())
        return OsmAnd::SkiaUtilities::createSkImageARGB888With(rawData, width, height);
    else
        return nullptr;
}

OsmAnd::MapStubStyle OAMapillaryTilesProvider::getDesiredStubsStyle() const
{
    return OsmAnd::MapStubStyle::Unspecified;
}

float OAMapillaryTilesProvider::getTileDensityFactor() const
{
    return 1.0f;
}

uint32_t OAMapillaryTilesProvider::getTileSize() const
{
    return 256 * _displayDensityFactor;
}

bool OAMapillaryTilesProvider::supportsNaturalObtainData() const
{
    return true;
}

bool OAMapillaryTilesProvider::supportsNaturalObtainDataAsync() const
{
    return true;
}

OsmAnd::ZoomLevel OAMapillaryTilesProvider::getMinZoom() const
{
    return OsmAnd::ZoomLevel15;
}

OsmAnd::ZoomLevel OAMapillaryTilesProvider::getMaxZoom() const
{
    return OsmAnd::ZoomLevel21;
}

void OAMapillaryTilesProvider::lockTile(const OsmAnd::TileId tileId, const OsmAnd::ZoomLevel zoom)
{
    QMutexLocker scopedLocker(&_tilesInProcessMutex);
    
    while(_tilesInProcess[zoom].contains(tileId))
        _waitUntilAnyTileIsProcessed.wait(&_tilesInProcessMutex);
    
    _tilesInProcess[zoom].insert(tileId);
}

void OAMapillaryTilesProvider::unlockTile(const OsmAnd::TileId tileId, const OsmAnd::ZoomLevel zoom)
{
    QMutexLocker scopedLocker(&_tilesInProcessMutex);
    
    _tilesInProcess[zoom].remove(tileId);
    
    _waitUntilAnyTileIsProcessed.wakeAll();
}

void OAMapillaryTilesProvider::setLocalCachePath(
                                                 const QString& localCachePath)
{
    QMutexLocker scopedLocker(&_localCachePathMutex);
    _vectorLocalCachePath = QDir(localCachePath).absoluteFilePath(_vectorPathSuffix);
}

OsmAnd::ZoomLevel OAMapillaryTilesProvider::getPointsZoom() const
{
    return OsmAnd::ZoomLevel17;
}

OsmAnd::ZoomLevel OAMapillaryTilesProvider::getVectorTileZoom() const
{
    return _vectorZoomLevel;
}

void OAMapillaryTilesProvider::performAdditionalChecks(sk_sp<SkImage> bitmap)
{
}
