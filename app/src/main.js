import './main.css';

import DATA from './data.json';

import $ from 'jquery';
import ons from 'onsenui/esm';
import 'onsenui/esm/elements/ons-navigator';
import 'onsenui/esm/elements/ons-page';
import 'onsenui/esm/elements/ons-toolbar';
import 'onsenui/esm/elements/ons-toolbar-button';
import 'onsenui/esm/elements/ons-back-button';
import 'onsenui/esm/elements/ons-button';
import 'onsenui/esm/elements/ons-icon';
import 'onsenui/esm/elements/ons-list';
import 'onsenui/esm/elements/ons-list-title';
import 'onsenui/esm/elements/ons-list-item';
import 'onsenui/esm/elements/ons-card';
import 'onsenui/esm/elements/ons-select';
import 'onsenui/esm/elements/ons-search-input';
import 'onsenui/esm/elements/ons-radio';
import 'onsenui/esm/elements/ons-dialog';
import 'onsenui/esm/elements/ons-popover';
import 'onsenui/esm/elements/ons-alert-dialog';
import 'onsenui/esm/elements/ons-alert-dialog-button';
import 'onsenui/esm/elements/ons-toast';
import {
  map       as LMap,
  control   as LControl,
  tileLayer as LTileLayer,
  popup     as LPopup,
  marker    as LMarker,
  icon      as LIcon,
} from 'leaflet';
import {
  MarkerClusterGroup as LMarkerClusterGroup,
} from 'leaflet.markercluster';

import MapMarkerUrl       from './map-marker.svg';
import MapMarkerShadowUrl from './map-marker-shadow.svg';
import GpsMarkerUrl       from './gps-marker.svg';

window.ons = ons;

// -----------------------------------------------------------------------------

const LANGUAGE_NAME           = {
                                  'en' : 'English',
                                  'tl' : 'Tagalog',
                                  'ceb': 'Cebuano',
                                  'ilo': 'Ilocano',
                                  'pam': 'Pampangan',
                                  'es' : 'Spanish',
                                  'de' : 'German',
                                  'fr' : 'French',
                                };
const IS_TRANSLATABLE         = {
                                  'en' : true,
                                  'tl' : true,
                                  'ceb': true,
                                  'ilo': false,
                                  'pam': false,
                                  'es' : true,
                                  'de' : true,
                                  'fr' : true,
                                };
const ORDERED_LANGUAGES       = ['en', 'tl', 'ceb', 'ilo', 'pam', 'es', 'de', 'fr'];
const EN_MONTH_NAMES          = 'Jan,Feb,Mar,Apr,May,Jun,Jul,Aug,Sep,Oct,Nov,Dec'.split(',');
const TL_MONTH_NAMES          = 'Ene,Peb,Mar,Abr,May,Hun,Hul,Ago,Set,Okt,Nob,Dis'.split(',');
const DEGREE_LENGTH           = 110.96;  // kilometers, adjusted
const DISTANCE_FILTERS        = [1, 2, 5, 10, 20, 50, 100];  // kilometers
const TILE_LAYER_URL          = 'https://cartodb-basemaps-{s}.global.ssl.fastly.net/rastertiles/voyager_labels_under/{z}/{x}/{y}{r}.png';
const TILE_LAYER_ATTRIBUTION  = 'Base map &copy; OSM (data), CARTO (style)';
const TILE_LAYER_MAX_ZOOM     = 19;
const MIN_PH_LAT              =   4.5;  // degrees
const MAX_PH_LAT              =  21.0;  // degrees
const MIN_PH_LON              = 116.5;  // degrees
const MAX_PH_LON              = 126.5;  // degrees
const GPS_ZOOM_LEVEL          = 12;
const PHOTO_MAX_WIDTH         = Math.floor($(window).width()) - 72;  // pixels
const PHOTO_MAX_HEIGHT        = Math.floor(PHOTO_MAX_WIDTH * 16 / 9);  // pixels
const PHOTO_PAGE_URL_TEMPLATE = 'https://commons.wikimedia.org/wiki/File:{filename}';
const THUMBNAIL_URL_TEMPLATE  = 'https://commons.wikimedia.org/wiki/Special:FilePath/File:{filename}?width={width}';
const MAX_CHUNK_LENGTH        = 50;  // markers processed
const SEARCH_DELAY            = 500;  // milliseconds
const DATE_LOCALE             = [
                                  'en-US',
                                  {
                                    month : 'long',
                                    day   : 'numeric',
                                    year  : 'numeric',
                                  },
                                ];
const ALT_QID                 = 'Q67080061';
const ALT_INSCRIPTION_HTML    =
  '<p class="blurb">The following is an alternate and “more complete” marker inscription <a target="_system" href="https://www.facebook.com/BaybayinAteneo/posts/853607714802471">as suggested by Baybayin</a>, a student organization at the Ateneo de Manila University.</p>' +
  '<p>Diktador. Naging pangulo, 1965 at 1969. Sinubukang ibagsak ng kabataan sa Unang Sigwa, 1970. Sinuspinde ang writ of habeas corpus, 1971. Ipinasa ang proclamation 1081 at nagdeklara ng Batas Militar, 1972. Nagpataw ng Bagong Saligang Batas, 1973. Isinabatas ang “Bagong Lipunan”, 1982. Tumakbo at nanalo sa huwad na halalan, 1981. Natalo sa snap elections ngunit inangkin pa rin ang pagkapangulo, 1986. Pinabagsak ng nagkaisang sambayanang Filipino, 1986. Tumakas sa Amerika at nanatili roon hanggang yumao, 1989. Patagong inilibing bilang bayani, 2016.</p>' +
  '<p>Pinatay, 3,275. Tinortyur, 35,000. Nawala, 1,600. Ninakaw, $10B.</p>';

// -----------------------------------------------------------------------------

// Global static helper objects
var OnsNavigator;
var Map;
var Cluster;
var MapPopup;
var MapPopupContent;
var MapPopupMarker;
var GpsMarker;

// Preferences
var VisitedFilterValue;
var BookmarkedFilterValue;
var RegionFilterValue;
var DistanceFilterValue;

// Global state and status flags
var Regions                 = {};
var ViewMode                = 'map';
var OnThisDayIsEnabled      = false;
var FilterDialogIsInit      = false;
var CurrentPosition;
var IsGeolocating           = false;
var GpsOffToastIsShown      = false;
var NumMarkersInitialized   = 0;
var CurrentMarkerInfo;
var StatusUpdatedMarkerQids = [];

// -----------------------------------------------------------------------------

initApp();

function initApp() {

  document.addEventListener('deviceready', initCordova.bind(this), false);

  // Further initialize in-memory DB
  Object.keys(DATA).forEach(qid => {
    const info = DATA[qid];
    info.qid = qid;
    const status = localStorage.getItem(qid);
    if (status) {
      info.visited    = status.substr(0, 1) === 'v';
      info.bookmarked = status.substr(1, 1) === 'b';
    }
    else {
      info.visited    = false;
      info.bookmarked = false;
    }
    if (typeof info.region === 'object') {
      info.region.forEach(value => { Regions[value] = true });
    }
    else {
      Regions[info.region] = true;
    }
  });

  // Initialize preferences
  VisitedFilterValue    = localStorage.getItem('visited-filter'   ) || 'any';
  BookmarkedFilterValue = localStorage.getItem('bookmarked-filter') || 'any';
  RegionFilterValue     = localStorage.getItem('region-filter'    );
  DistanceFilterValue   = localStorage.getItem('distance-filter'  );
  if (DistanceFilterValue) DistanceFilterValue = parseInt(DistanceFilterValue);

  // Set app first open time
  if (!localStorage.getItem('PN-first-open')) {
    localStorage.setItem('PN-first-open', new Date().getTime());
  }
}

// -----------------------------------------------------------------------------

function initCordova() {
  screen.orientation.lock('portrait');
  if (cordova.platformId === 'android') {
    StatusBar.backgroundColorByHexString("#123");
  }
}

// -----------------------------------------------------------------------------

function initMain() {

  if ('splashscreen' in navigator) navigator.splashscreen.hide();

  OnsNavigator = document.getElementById('navigator');

  $('#view-mode-button').click(toggleView);
  $('#this-day-button' ).click(toggleOnThisDay);
  $('#filter-button'   ).click(openFilterDialog);
  $('#main-menu-button').click(showMainMenu);

  initMap();
  initList();
  initFlatTexts();

  generateMapMarkersAndListItems();
  $('#explore').on('initfinished', () => {
    if (DistanceFilterValue) {
      applyFilters({ suppressToast: true });
      geolocateUser();
    }
    else {
      applyFilters();
    }
    setTimeout(
      function() {
        const splashScreen = document.getElementById('splash');
        splashScreen.style.opacity = 0;
        setTimeout(() => { splashScreen.parentNode.removeChild(splashScreen) }, 1000);
      },
      100
    );
  });
};

// -----------------------------------------------------------------------------

function initMap() {

  const bg = $('#explore .page__background');
  $('#map').width (bg.width ());
  $('#map').height(bg.height());

  // Create map and set initial view
  Map = new LMap('map', { attributionControl: false });
  LControl.attribution({ prefix: false }).addTo(Map);
  Map.fitBounds([[MAX_PH_LAT, MAX_PH_LON], [MIN_PH_LAT, MIN_PH_LON]]);

  // Add geolocation button
  const locButton = LControl({ position: 'topleft'});
  locButton.onAdd = function() {
    const controlDiv = $('<div class="leaflet-bar leaflet-control"></div>');
    controlDiv.append('<a id="gps-button"><ons-icon icon="md-gps-dot"></ons-icon></a>');
    controlDiv.click(geolocateUser);
    return controlDiv[0];
  };
  locButton.addTo(Map);

  // Add tile layer
  new LTileLayer(
    TILE_LAYER_URL,
    {
      attribution : TILE_LAYER_ATTRIBUTION,
      maxZoom     : TILE_LAYER_MAX_ZOOM,
    },
  ).addTo(Map);

  // Initialize the map marker cluster
  Cluster = new LMarkerClusterGroup({
    maxClusterRadius: z => {
      if (z <=  15) return 50;
      if (z === 16) return 40;
      if (z === 17) return 30;
      if (z === 18) return 20;
      if (z >=  19) return 10;
    },
    showCoverageOnHover: false,
  }).addTo(Map);

  // Initialize the reusable map popup
  MapPopupContent = $(
    '<div class="popup-wrapper">' +
      '<div class="popup-title"></div>' +
      '<span data-action="visited"      class="zmdi zmdi-eye-off"         ></span>' +
      '<span data-action="unvisited"    class="zmdi zmdi-eye"             ></span>' +
      '<span data-action="bookmarked"   class="zmdi zmdi-bookmark-outline"></span>' +
      '<span data-action="unbookmarked" class="zmdi zmdi-bookmark"        ></span>' +
      '<ons-button modifier="quiet">Details</ons-button>' +
    '</div>'
  )[0];
  MapPopup = LPopup({ closeButton: false }).setContent(MapPopupContent);

  // Click event handling using event delegation
  $('#map').click(e => {
    const clickedElem = e.target;
    if (clickedElem.tagName === 'SPAN' && ('action' in clickedElem.dataset)) {
      e.stopPropagation();
      updateStatus(clickedElem.parentNode.dataset.qid, clickedElem.dataset.action);
    }
    else if (clickedElem.tagName === 'ONS-BUTTON') {
      e.stopPropagation();
      OnsNavigator.pushPage(
        'details.html',
        { data: { info: DATA[clickedElem.parentNode.dataset.qid] } },
      );
    }
    else if (clickedElem.tagName === 'IMG' && clickedElem.classList.contains('leaflet-marker-icon')) {
      e.stopPropagation();
      const info = DATA[clickedElem.className.match(/Q[0-9]+/)[0]];
      updatePopup(info);
      info.mapMarker.bindPopup(MapPopup).openPopup();
      MapPopupMarker = info.mapMarker;
    }
  });
}

// -----------------------------------------------------------------------------

function initList() {

  const bg = $('#explore .page__background');
  $('#main-list').width (bg.width ());
  $('#main-list').height(bg.height());

  let searchInputTimeoutId;
  $('#main-list ons-search-input input').on('input', () => {
    clearTimeout(searchInputTimeoutId);
    searchInputTimeoutId = setTimeout(applySearch, SEARCH_DELAY);
  });
  $('#missing-info-notice ons-button').click(showContributing);

  // Click event handling using event delegation
  $('#main-list ons-list').click(e => {
    const clickedElem = e.target;
    if (clickedElem.tagName === 'SPAN' && ('action' in clickedElem.dataset)) {
      e.stopPropagation();
      updateStatus(clickedElem.dataset.qid, clickedElem.dataset.action);
    }
    else {
      e.stopPropagation();
      let elem = clickedElem;
      while (!('qid' in clickedElem.dataset)) elem = elem.parentElement;
      OnsNavigator.pushPage(
        'details.html',
        { data: { info: DATA[clickedElem.dataset.qid] } },
      );
    }
  });
}

// -----------------------------------------------------------------------------

function generateMapMarkersAndListItems() {

  const qids = Object.keys(DATA);
  const numMarkers = qids.length;
  const progressElem = document.getElementById('load-status');
  const progressMaxWidth = document.getElementById('load-progress').clientWidth - 10;

  const processChunk = function(startIdx) {

    let idx = startIdx;
    for (; idx < numMarkers && idx < startIdx + MAX_CHUNK_LENGTH; idx++) {

      const qid = qids[idx];
      const info = DATA[qid];

      const mapMarker = LMarker(
        [info.lat, info.lon],
        {
          icon: LIcon({
            iconUrl      : MapMarkerUrl,
            iconSize     : [25, 38.6905],
            iconAnchor   : [12, 36],
            popupAnchor  : [0, -30],
            shadowUrl    : MapMarkerShadowUrl,
            shadowSize   : [40, 30],
            shadowAnchor : [6, 23],
            className    : qid,
          }),
        },
      );
      info.mapMarker = mapMarker;

      const li = $(
        `<ons-list-item data-qid="${qid}" class="` +
          (info.visited    ? ' visited'    : '') +
          (info.bookmarked ? ' bookmarked' : '') +
        '">' +
          '<div class="center">' +
            `<div class="name">${info.name}</div>` +
            `<div class="address">${info.macroAddress}</div>` +
            '<div class="distance"></div>' +
          '</div>' +
          '<div class="right">' +
            `<span data-qid="${qid}" data-action="visited"      class="zmdi zmdi-eye-off"         ></span>` +
            `<span data-qid="${qid}" data-action="unvisited"    class="zmdi zmdi-eye"             ></span>` +
            `<span data-qid="${qid}" data-action="bookmarked"   class="zmdi zmdi-bookmark-outline"></span>` +
            `<span data-qid="${qid}" data-action="unbookmarked" class="zmdi zmdi-bookmark"        ></span>` +
          '</div>' +
        '</ons-list-item>'
      );
      info.mainListItem = li[0];

      NumMarkersInitialized++;
    }

    const progress = NumMarkersInitialized / numMarkers;
    progressElem.style.width = (progressMaxWidth * progress + 10) + 'px';
    if (idx + 1 <= numMarkers) {
      setTimeout(processChunk, 17, idx);
    }
    else {
      if (NumMarkersInitialized === numMarkers) $('#explore').trigger('initfinished');
    }
  };

  processChunk(0);
}

// -----------------------------------------------------------------------------

function initFlatTexts() {
  const textTypes = ['title', 'subtitle', 'inscription'];
  Object.values(DATA).forEach(record => {
    const details = record.details;
    const textHashes = 'text' in details
      ? Object.values(details.text)
      : Object.values(details).map(l10n => l10n.text);
    record.flatText = textHashes.map(textHash => textTypes.map(textType => textHash[textType] || '').join('\n')).join('\n');
  })
}

// -----------------------------------------------------------------------------

function toggleOnThisDay() {
  OnThisDayIsEnabled = !OnThisDayIsEnabled;
  $('#this-day-button').attr('icon', 'md-calendar' + (OnThisDayIsEnabled ? '-check' : ''));
  applyFilters();
}

// -----------------------------------------------------------------------------

function toggleView() {
  if (ViewMode === 'map') showList();
  else                    showMap();
}

// -----------------------------------------------------------------------------

function showMap() {
  ViewMode = 'map';
  $('#explore ons-toolbar .left').text('Map view');
  $('#view-mode-button').attr('icon', 'md-view-list');
  $('#map').css('z-index', 1);
  $('#map').css('opacity', 1);
  $('#main-list').css('z-index', 0);
  $('#main-list').css('opacity', 0);
}

// -----------------------------------------------------------------------------

function showList() {
  ViewMode = 'list';
  $('#explore ons-toolbar .left').text('List view');
  $('#view-mode-button').attr('icon', 'md-map');
  $('#main-list').css('z-index', 1);
  $('#main-list').css('opacity', 1);
  $('#map').css('z-index', 0);
  $('#map').css('opacity', 0);
}

// -----------------------------------------------------------------------------

function updatePopup(info) {
  MapPopupContent.dataset.qid = info.qid;
  if (info.visited) {
    MapPopupContent.classList.add('visited');
  }
  else {
    MapPopupContent.classList.remove('visited');
  }
  if (info.bookmarked) {
    MapPopupContent.classList.add('bookmarked');
  }
  else {
    MapPopupContent.classList.remove('bookmarked');
  }
  MapPopupContent.querySelector('.popup-title').innerHTML = info.name;
  MapPopupContent.querySelector('ons-button').dataset.qid = info.qid;
}

// -----------------------------------------------------------------------------

function geolocateUser() {

  if (IsGeolocating) return;

  // Wrapper logic to check if GPS is enabled
  if (typeof gpsDetect !== 'undefined') {
    gpsDetect.checkGPS(
      function(gpsIsEnabled) {
        if (gpsIsEnabled) {
          startGeolocating();
        }
        else {
          if (!GpsOffToastIsShown) {
            GpsOffToastIsShown = true;
            ons.notification
              .toast('You need to turn GPS on first', { timeout: 2000 })
              .then(() => { GpsOffToastIsShown = false });
          }
        }
      },
      startGeolocating,
    );
  }
  else {
    startGeolocating();
  }
}

// -----------------------------------------------------------------------------

function startGeolocating() {
  IsGeolocating = true;
  ons.notification.toast('Getting GPS location...', { timeout: 1000 });
  $('#gps-button ons-icon').attr('icon', 'md-spinner').attr('spin', 'spin');
  setTimeout(
    function() {
      navigator.geolocation.getCurrentPosition(
        processUserPosition,
        handleGeolocatingError,
        { timeout: 60000, maximumAge: 60000 },
      );
    },
    200
  );
}

// -----------------------------------------------------------------------------

function stopGeolocating() {
  IsGeolocating = false;
  $('#gps-button ons-icon').attr('icon', 'md-gps-dot').removeAttr('spin');
}

// -----------------------------------------------------------------------------

function processUserPosition(position) {

  stopGeolocating();

  // Invalidate all distances
  Object.values(DATA).forEach(info => { info.distance = null });
  CurrentPosition = {
    lat: position.coords.latitude,
    lon: position.coords.longitude,
  };

  // Update map state
  if (!GpsMarker) {
    const icon = LIcon({
      iconUrl    : GpsMarkerUrl,
      iconSize   : [48, 48],
      iconAnchor : [24, 24],
    });
    GpsMarker = LMarker(
      CurrentPosition,
      {
        icon        : icon,
        pane        : 'shadowPane',
        interactive : false,
      },
    ).addTo(Map);
  }
  else {
    GpsMarker.setLatLng(CurrentPosition);
  }
  if (Map.getZoom() < GPS_ZOOM_LEVEL) {
    Map.setView(CurrentPosition, GPS_ZOOM_LEVEL);
  }
  else {
    Map.panTo(CurrentPosition);
  }

  if (DistanceFilterValue) applyFilters();
}

// -----------------------------------------------------------------------------

function handleGeolocatingError() {
  stopGeolocating();
  ons.notification.toast(
    'Cannot get GPS location',
    {
      force       : true,
      buttonLabel : 'OK',
    },
  );
}

// -----------------------------------------------------------------------------

function applySearch() {

  // Prepare query
  let query = document.querySelector('#main-list ons-search-input input').value;
  query = query.replace(/^\s+|\s+$/g, '');  // Remove trailing spaces
  query = query.replace(/[[\]{}()*+!<=:?\/\\^$|#,@]/g, '');  // Remove some punctuation
  query = query.replace(/\./g, '\\$&');  // Escape periods
  const terms = query.split(/\s+/);
  const regex = new RegExp(terms.map(x => `(?=.*${x})`).join(''), 'i');

  // Perform search filtering
  let numPotentialResults = 0;
  let numActualResults    = 0;
  Object.values(DATA).forEach(info => {
    if (!info.visible) return;
    numPotentialResults++;
    if (regex.test(info.name + ' ' + info.macroAddress)) {
      numActualResults++;
      $(info.mainListItem).show();
    }
    else {
      $(info.mainListItem).hide();
    }
  });

  // Control messages
  if (query.length > 0) {
    const msg = $('#search-results-msg');
    if (numActualResults === 0) {
      msg.text('No results');
      $('#missing-info-notice').show();
    }
    else {
      msg.text(`Showing ${numActualResults} result${(numActualResults > 1 ? 's' : '')} out of ${numPotentialResults}`);
      $('#missing-info-notice').hide();
    }
    msg.slideDown();
  }
  else {
    $('#search-results-msg' ).slideUp();
    $('#missing-info-notice').hide();
  }
}

// -----------------------------------------------------------------------------

function initFilterDialog() {

  // Convert Regions hash into a sorted array
  Regions = [...Object.keys(Regions).sort()];

  const regionSelect = $('<ons-select id="region-filter"></ons-select>');
  regionSelect.append('<option val="0">any region</option>');
  Regions.forEach(value => {
    const selectedAttr = RegionFilterValue === value ? 'selected' : '';
    regionSelect.append(`<option val="${value}" ${selectedAttr}>${value}</option>`);
  });
  $('#region-filter-wrapper').append(regionSelect);

  const distanceSelect = $('<ons-select id="distance-filter"></ons-select>');
  distanceSelect.append('<option val="0">any distance</option>');
  DISTANCE_FILTERS.forEach(value => {
    const selectedAttr = DistanceFilterValue === value ? 'selected' : '';
    distanceSelect.append(`<option val="${value}" ${selectedAttr}>within ${value} km</option>`);
  });
  $('#distance-filter-wrapper').append(distanceSelect);
}

// -----------------------------------------------------------------------------

function openFilterDialog() {

  // Lazy loading
  if (!FilterDialogIsInit) {
    FilterDialogIsInit = true;
    initFilterDialog();
  }

  document.getElementById('filter-dialog').show();
  const vRadios = $('ons-radio[name="visited-option"   ]');
  const bRadios = $('ons-radio[name="bookmarked-option"]');
  [0, 1, 2].forEach(i => {
    if (VisitedFilterValue    === vRadios[i].value) vRadios[i].checked = true;
    if (BookmarkedFilterValue === bRadios[i].value) bRadios[i].checked = true;
  });
}

// -----------------------------------------------------------------------------

function closeFilterDialog() {

  const prevVisited    = VisitedFilterValue;
  const prevBookmarked = BookmarkedFilterValue;
  const prevRegion     = RegionFilterValue;
  const prevDistance   = DistanceFilterValue;

  // Update filter values
  const vRadios = $('ons-radio[name="visited-option"   ]');
  const bRadios = $('ons-radio[name="bookmarked-option"]');
  [0, 1, 2].forEach(i => {
    if (vRadios[i].checked) VisitedFilterValue    = vRadios[i].value;
    if (bRadios[i].checked) BookmarkedFilterValue = bRadios[i].value;
  });
  const onsSelect = document.getElementById('region-filter');
  RegionFilterValue = onsSelect.selectedIndex === 0 ? null : onsSelect.value;
  const index = document.getElementById('distance-filter').selectedIndex;
  DistanceFilterValue = index === 0 ? null : DISTANCE_FILTERS[index - 1];
  if (!CurrentPosition && index > 0) geolocateUser();

  // Save filter values
  localStorage.setItem('visited-filter'   , VisitedFilterValue   );
  localStorage.setItem('bookmarked-filter', BookmarkedFilterValue);
  if (RegionFilterValue) {
    localStorage.setItem('region-filter', RegionFilterValue);
  }
  else {
    localStorage.removeItem('region-filter');
  }
  if (DistanceFilterValue) {
    localStorage.setItem('distance-filter', DistanceFilterValue);
  }
  else {
    localStorage.removeItem('distance-filter');
  }

  // If filter values have changed, reset search bar and apply filters
  if (
    prevVisited    !== VisitedFilterValue    ||
    prevBookmarked !== BookmarkedFilterValue ||
    prevRegion     !== RegionFilterValue     ||
    prevDistance   !== DistanceFilterValue
  ) {
    document.querySelector('#main-list ons-search-input input').value = '';
    applyFilters();
  }

  document.getElementById('filter-dialog').hide();
}

// -----------------------------------------------------------------------------

// Shows or hides the map marker and main list items corresponding to each
// historical marker depending on whether they match the current filters.
// Options:
// - suppressToast : set to true to disable the toast message
function applyFilters(options = {}) {

  const visibleQids = [], visibleMapMarkers = [];

  const today = new Date;
  let todayRegex;
  if (OnThisDayIsEnabled) {

    const monthIdx = today.getMonth();
    const enMonth = EN_MONTH_NAMES[monthIdx];
    const tlMonth = TL_MONTH_NAMES[monthIdx];
    const date = today.getDate();

    todayRegex = new RegExp(
      `\\b${date} (?:${enMonth}|${tlMonth})|` +
      `ika-${date} ng ${tlMonth}|` +
      `(?:${enMonth}|${tlMonth})[a-z]* ${date}\\b`
    );
  }

  Object.keys(DATA).forEach(qid => {
    const info = DATA[qid];
    if (
      doesMarkerMatchFilters(info) &&
      (!OnThisDayIsEnabled || todayRegex.test(info.flatText))
    ) {
      visibleQids.push(qid);
      visibleMapMarkers.push(info.mapMarker);
      $(info.mainListItem).show();
      info.visible = true;
    }
    else {
      $(info.mainListItem).hide();
      info.visible = false;
    }
  });
  Cluster.clearLayers();
  Cluster.addLayers(visibleMapMarkers);

  sortMainList(visibleQids);

  // If the distance filter has kicked in because of a delay in getting
  // the GPS location, we need to re-apply the search
  applySearch();

  // Show toast or alert message as needed
  const numVisible = visibleQids.length;
  let msg = null;
  if (numVisible === 0) {
    const isFiltered =
      VisitedFilterValue    !== 'any' ||
      BookmarkedFilterValue !== 'any' ||
      RegionFilterValue     !== null  ||
      DistanceFilterValue   !== null;
    msg = OnThisDayIsEnabled
      ? `Sadly, there are no relevant historical markers today${isFiltered ? ' that match your current filters' : ''}. ☹️`
      : 'No historical markers match the filters';
  }
  else if (!('suppressToast' in options) || !options.suppressToast) {
    const markersWord = ` marker${numVisible > 1 ? 's' : ''}`;
    msg = OnThisDayIsEnabled
      ? `On this day, there ${numVisible > 1 ? 'are' : 'is'} ${numVisible} relevant historical ${markersWord} for you to explore!`
      : `Now showing ${numVisible} historical ${markersWord}`;
  }
  if (msg) {
    if (OnThisDayIsEnabled) {
      const prevAlert = document.getElementById('today-alert');
      if (prevAlert) prevAlert.hide({ animation: 'none' });
      ons.notification.alert(
        msg,
        {
          id         : 'today-alert',
          title      : today.toLocaleDateString(...DATE_LOCALE),
          cancelable : true,
        },
      );
    }
    else {
      ons.notification.toast(msg, { timeout: 2000 });
    }
  }
}

// -----------------------------------------------------------------------------

function hideStatusUpdatedMarkers() {
  const mapMarkers = [];
  StatusUpdatedMarkerQids.forEach(qid => {
    const info = DATA[qid];
    if (!doesMarkerMatchFilters(info)) {
      mapMarkers.push(info.mapMarker);
      $(info.mainListItem).hide();
      info.visible = false;
    }
  });
  Cluster.removeLayers(mapMarkers);
  StatusUpdatedMarkerQids = [];
}

// -----------------------------------------------------------------------------

// Sorts the main list either alphabetically or by distance
// given the list of QIDs of the visible historical markers
function sortMainList(qids) {
  const list = document.querySelector('#main-list ons-list');
  if (DistanceFilterValue && CurrentPosition) {
    list.classList.remove('sorted-alphabetically');
    qids.sort((a, b) => DATA[a].distance - DATA[b].distance);
  }
  else {
    list.classList.add('sorted-alphabetically');
    qids.sort((a, b) => {
      if (DATA[a].name < DATA[b].name) return -1;
      if (DATA[a].name > DATA[b].name) return  1;
      return 0;
    });
  }
  list.innerHTML = '';
  const fragment = document.createDocumentFragment();
  qids.forEach(qid => { fragment.appendChild(DATA[qid].mainListItem) });
  list.appendChild(fragment);
}

// -----------------------------------------------------------------------------

// Returns true if the specified marker (passed as record) matches the current filters
function doesMarkerMatchFilters(info) {
  return (
    (
      VisitedFilterValue === 'any' ||
      VisitedFilterValue === 'yes' &&  info.visited ||
      VisitedFilterValue === 'no'  && !info.visited
    )
    &&
    (
      BookmarkedFilterValue === 'any' ||
      BookmarkedFilterValue === 'yes' &&  info.bookmarked ||
      BookmarkedFilterValue === 'no'  && !info.bookmarked
    )
    &&
    (
      RegionFilterValue === null ||
      typeof info.region === 'object' && info.region.includes(RegionFilterValue) ||
      info.region === RegionFilterValue
    )
    &&
    (
      DistanceFilterValue === null ||
      !CurrentPosition ||
      isMarkerNear(info)
    )
  );
}

// -----------------------------------------------------------------------------

function isMarkerNear(info) {

  // Quickly eliminate too far markers to avoid exact distance computation
  const maxDegreeDiff = 2 * DistanceFilterValue / DEGREE_LENGTH;  // Double to adjust for higher latitudes
  if (Math.abs(info.lat - CurrentPosition.lat) > maxDegreeDiff) return false;
  if (Math.abs(info.lon - CurrentPosition.lon) > maxDegreeDiff) return false;

  if (!info.distance) computeDistanceToMarker(info);
  return info.distance <= DistanceFilterValue * 1000;
}

function computeDistanceToMarker(info) {

  // Uses a simple Euclidean formula for faster calculation
  const x =  CurrentPosition.lat - info.lat;
  const y = (CurrentPosition.lon - info.lon) * Math.cos(CurrentPosition.lat * Math.PI / 180);
  const distance = Math.round(DEGREE_LENGTH * 1000 * Math.hypot(x, y));
  info.distance = distance;

  // Generate UI distance string (generally 2 significant figures)
  const distanceLabel =
    distance <= 100
      ? distance + ' m'
      : distance <= 1000
        ? (Math.round(distance / 10) * 10) + ' m'
        : distance <= 10000
          ? (Math.round(distance / 100) / 10) + ' km'
          : (Math.round(distance / 1000)) + ' km';
  info.mainListItem.querySelector('.distance').innerHTML = distanceLabel;
}

// -----------------------------------------------------------------------------

function showMainMenu() {
  const button = document.querySelector('ons-toolbar-button[icon="md-more-vert"]');
  document.getElementById('main-menu').show(button);
}

function showMiscPage(templateId) {
  document.getElementById('main-menu').hide();
  OnsNavigator.pushPage(templateId);
}

function showContributing () { showMiscPage('contributing.html'  ); }
function showResources    () { showMiscPage('resources.html'     ); }
function showPrivacyPolicy() { showMiscPage('privacy-policy.html'); }
function showAbout        () { showMiscPage('about.html'         ); }

function initAbout() {
  $('#about-logo').width(Math.floor(window.innerWidth / 3));
}

// -----------------------------------------------------------------------------

function initMarkerDetails() {

  const info = this.data.info;
  CurrentMarkerInfo = info;

  $('ons-back-button').click(hideStatusUpdatedMarkers);

  // Set toolbar title
  $('#details .toolbar__title').append(info.name);

  const top = $(this).find('#details-content');

  // Activate status buttons
  // ------------------------------------------------------

  const page = $('#details');
  if (info.visited   ) page.addClass('visited'   );
  if (info.bookmarked) page.addClass('bookmarked');

  const notVisitedButton    = $('ons-toolbar-button[icon="md-eye-off"         ]');
  const visitedButton       = $('ons-toolbar-button[icon="md-eye"             ]');
  const notBookmarkedButton = $('ons-toolbar-button[icon="md-bookmark-outline"]');
  const bookmarkedButton    = $('ons-toolbar-button[icon="md-bookmark"        ]');
  notVisitedButton   .click(() => { updateStatus(info.qid, 'visited'     ) });
  visitedButton      .click(() => { updateStatus(info.qid, 'unvisited'   ) });
  notBookmarkedButton.click(() => { updateStatus(info.qid, 'bookmarked'  ) });
  bookmarkedButton   .click(() => { updateStatus(info.qid, 'unbookmarked') });

  // Construct list for marker details
  // ------------------------------------------------------

  const detailsList = $('<ons-list></ons-list>');

  const dateLi      = generateIconedListItem('calendar');
  const mainPhotoLi = generateIconedListItem('camera');
  const textLi      = generateIconedListItem('format-subject', { hasDivider: true });

  // Add singular unveiling date
  if (info.date !== true) {
    detailsList.append(dateLi.item);
    dateLi.contents.append(generateMarkerDateString(info.date));
  }

  // Default is plaque(s) is monolingual
  let l10nData = info.details;
  let plaqueIsMonolingual = true;

  // Adjust if plaque is multilingual
  if ('text' in info.details) {
    l10nData = info.details.text;
    plaqueIsMonolingual = false;
  }

  // Add photo for multilingual plaque
  if (!plaqueIsMonolingual) {
    detailsList.append(mainPhotoLi.item)
    mainPhotoLi.contents.append(generateFigure(info.details.photo));
  }

  // Add language list item (unless monolingual English)
  const langCodes = $.grep(ORDERED_LANGUAGES, x => l10nData[x]);
  const hasNoEnglish = langCodes[0] !== 'en';
  let segment;
  if (langCodes.length > 1 || hasNoEnglish) {
    const li = generateIconedListItem('translate');
    detailsList.append(li.item);
    if (langCodes.length > 1) {
      segment = $('<div class="segment segment--material"></div>');
      li.contents.append(segment);
    }
    else if (hasNoEnglish) {
      li.contents.append(LANGUAGE_NAME[langCodes[0]]);
    }
  }

  // Add each language details
  langCodes.forEach((code, index) => {

    // Add language to segment
    if (langCodes.length > 1) {
      const segmentItem = $(
        '<div class="segment__item segment--material__item">' +
        '<input type="radio" class="segment__input segment--material__input" name="segment-lang"' +
        (index === 0 ? ' checked' : '') +
        '><div class="segment__button segment--material__button">' +
        LANGUAGE_NAME[code] +
        '</div>'
      );
      segmentItem.click(() => {
        $('.multilingual.' + code).addClass('active');
        $(`.multilingual:not(.${code})`).removeClass('active');
      });
      segment.append(segmentItem);
    }

    // Process multilingual dates
    if (info.date === true) {
      const text = generateMarkerDateString(l10nData[code].date);
      const span = $(`<span class="multilingual ${code}">${text}</span>`);
      dateLi.contents.append(span);
      if (index === 0) detailsList.append(dateLi.item);
    }

    // Add photo(s) for monolingual marker
    if (plaqueIsMonolingual) {
      // Convert to array to support Tanay triptych marker
      if (!Array.isArray(l10nData[code].photo)) l10nData[code].photo = [l10nData[code].photo];
      l10nData[code].photo.forEach(photoData => {
        const figure = generateFigure(photoData);
        figure.addClass(['multilingual', code]);
        mainPhotoLi.contents.append(figure);
      });
      if (index === 0) detailsList.append(mainPhotoLi.item);
    }

    // Process text
    const textData = (plaqueIsMonolingual ? l10nData[code].text : l10nData[code]);
    const textDiv = $(`<div class="marker-text multilingual ${code}"></div>`);
    const isTranslatable = hasNoEnglish && IS_TRANSLATABLE[code];
    let translatableText = '';
    if (textData.title) {
      textDiv.append(`<h2>${textData.title}</h2>`);
      if (isTranslatable) translatableText += textData.title.replace('<br>', '\n');
      if (textData.subtitle) {
        textDiv.append(`<h3>${textData.subtitle}</h3>`);
        if (isTranslatable) translatableText += '\n' + textData.subtitle.replace('<br>', '\n');
      }
    }
    if (textData.inscription === '') {
      textDiv.append('<p class="nodata">No inscription encoded yet.</p>');
    }
    else if (textData.inscription) {
      textDiv.append(textData.inscription);
      if (isTranslatable) {
        translatableText += '\n\n' + textData.inscription
          .replace(/<\/p><p>/g, '\n\n')
          .replace(/<br>/g, '\n')
          .replace(/<[^>]+>/g, '');
      }
    }
    if (isTranslatable) {
      const url = `https://translate.google.com/#${code}/en/${encodeURIComponent(translatableText)}`;
      textDiv.append(`<p class="translate-link"><a target="_system" href="${url}">Translate into English</a></p>`);
    }
    textLi.contents.append(textDiv);
    if (index === 0) detailsList.append(textLi.item);

    // Make first language active
    if (index === 0) detailsList.find('.multilingual').addClass('active');
  });

  // Add anti-revisionism text
  if (info.qid === ALT_QID) {
    const altLi = generateIconedListItem('comment-alt-text');
    altLi.contents.addClass('alt-inscription');
    altLi.contents.append(ALT_INSCRIPTION_HTML);
    detailsList.append(altLi.item);
  }

  // Add Wikipedia links
  if (info.wikipedia) {
    const wikiLi = generateIconedListItem('wikipedia');
    wikiLi.contents.addClass('wikipedia-links');
    wikiLi.contents.append('<h3>Learn more on Wikipedia</h3>');
    Object.keys(info.wikipedia).forEach(title => {
      const urlPath = info.wikipedia[title] === true ? title : info.wikipedia[title];
      const linkP = $(`<p><a target="_system" href="https://en.wikipedia.org/wiki/${encodeURIComponent(urlPath)}">${title}</a></p>`);
      wikiLi.contents.append(linkP);
    });
    detailsList.append(wikiLi.item);
  }

  // Add Commons link
  if (info.commons) {
    const commonsLi = generateIconedListItem('collection-image');
    commonsLi.contents.addClass('commons-link');
    commonsLi.contents.append(`<a target="_system" href="https://commons.wikimedia.org/wiki/Category:${info.commons}">View more photos from Wikimedia Commons</a>`);
    detailsList.append(commonsLi.item);
  }

  top.append($('<ons-list-title>Details</ons-list-title>'));
  top.append(detailsList);

  // Construct list for marker location
  // ------------------------------------------------------

  const locList = $('<ons-list></ons-list>');

  const locButton = $('<ons-button id="loc-menu-button"><ons-icon icon="md-pin-drop"></ons-icon></ons-button>');
  locButton.click(e => { document.getElementById('loc-menu').show(e) });

  const addressLi = generateIconedListItem('pin', { hasRight: true });
  locList.append(addressLi.item);
  addressLi.contents.append(info.address);
  addressLi.item.find('.right').append(locButton);

  if (info.locDesc) {
    const directionsLi = generateIconedListItem('info-outline');
    locList.append(directionsLi.item);
    directionsLi.contents.append(info.locDesc);
  }

  if (info.locPhoto) {
    const locationPhotoLi = generateIconedListItem('camera');
    locList.append(locationPhotoLi.item);
    locationPhotoLi.contents.append(generateFigure(info.locPhoto));
  }

  top.append('<ons-list-title>Location</ons-list-title>');
  top.append(locList);
};

// -----------------------------------------------------------------------------

function generateIconedListItem(iconCode, options = {}) {
  const rightHtml   = 'hasRight'   in options ? '<div class="right"></div>' : '';
  const dividerAttr = 'hasDivider' in options ? 'longdivider' : 'nodivider';
  const li = $(`<ons-list-item modifier="${dividerAttr}"><div class="left"><ons-icon icon="md-${iconCode}" class="list-item__icon"></ons-icon></div><div class="center"></div>${rightHtml}</ons-list-item>`);
  const contents = li.find('.center');
  li.append(contents);
  return {
    item     : li,
    contents : contents,
  };
}

// -----------------------------------------------------------------------------

function generateMarkerDateString(dateString) {
  return (
    !dateString
      ? '<p class="nodata">Unveiling date unknown</p>'
      : dateString.length === 4
        ? 'Unveiled in ' + dateString
        : 'Unveiled on ' + new Date(dateString).toLocaleDateString(...DATE_LOCALE)
  );
}

// -----------------------------------------------------------------------------

function generateFigure(photoData) {

  const figure = $('<figure></figure>');

  if (photoData) {

    const width = photoData.height / photoData.width <= 16 / 9
      ? PHOTO_MAX_WIDTH
      : PHOTO_MAX_HEIGHT / photoData.height * photoData.width;
    const height = width / photoData.width * photoData.height;
    const encodedFilename = encodeURIComponent(photoData.file.replace(/ /g, '_'));
    const pageUrl = PHOTO_PAGE_URL_TEMPLATE.replace('{filename}', encodedFilename);
    const thumbUrl = THUMBNAIL_URL_TEMPLATE
      .replace('{filename}', encodedFilename)
      .replace('{width}', Math.floor(width * 2));

    const anchor = $(`<a target="_system" href="${pageUrl}"></a>`);
    anchor.width(width);
    anchor.height(height);
    anchor.append(`<img src="${thumbUrl}" width="${width}" height="${height}">`);
    figure.append(anchor);
    figure.append(`<figcaption>${photoData.credit}</figcaption>`);
  }

  // No actual photo
  else {
    figure.addClass('nodata');
    figure.css('padding', Math.floor(PHOTO_MAX_WIDTH / 5) + 'px 16px');
    figure.css('width', PHOTO_MAX_WIDTH + 'px');
    figure.append('<div>No photo available yet</div>');
    const button = $('<ons-button>Contribute</ons-button>');
    button.click(showContributing);
    figure.append(button);
  }

  return figure;
}

// -----------------------------------------------------------------------------

function showMarkerOnMap() {
  document.getElementById('loc-menu').hide();
  showMap();
  if (MapPopupMarker) MapPopupMarker.closePopup();
  updatePopup(CurrentMarkerInfo);
  OnsNavigator.popPage({
    animation : 'slide',
    callback  : () => {
      Cluster.zoomToShowLayer(
        CurrentMarkerInfo.mapMarker,
        () => {
          Map.panTo([CurrentMarkerInfo.lat, CurrentMarkerInfo.lon]);
          CurrentMarkerInfo.mapMarker.bindPopup(MapPopup).openPopup();
          MapPopupMarker = CurrentMarkerInfo.mapMarker;
        },
      );
    },
  });
}

// -----------------------------------------------------------------------------

function showLocationInMapApp() {
  document.getElementById('loc-menu').hide();
  window.open(`geo:${CurrentMarkerInfo.lat},${CurrentMarkerInfo.lon}?z=20`);
}

// -----------------------------------------------------------------------------

function updateStatus(qid, status) {

  const info = DATA[qid];
  const page = document.getElementById('details');

  // Update internal DB and button states and show toast
  const toastOptions = {
    timeout : 1000,
    force   : true,
  };
  if (status === 'visited') {
    info.visited = true;
    info.mainListItem.classList.add('visited');
    MapPopupContent  .classList.add('visited');
    if (page) page   .classList.add('visited')
    ons.notification.toast('Marked as visited', toastOptions);
  }
  else if (status === 'unvisited') {
    info.visited = false;
    info.mainListItem.classList.remove('visited');
    MapPopupContent  .classList.remove('visited');
    if (page) page   .classList.remove('visited');
    ons.notification.toast('Marked as not visited', toastOptions);
  }
  else if (status === 'bookmarked') {
    info.bookmarked = true;
    info.mainListItem.classList.add('bookmarked');
    MapPopupContent  .classList.add('bookmarked');
    if (page) page   .classList.add('bookmarked');
    ons.notification.toast('Added to bookmarks', toastOptions);
  }
  else { // status === 'unbookmarked'
    info.bookmarked = false;
    info.mainListItem.classList.remove('bookmarked');
    MapPopupContent  .classList.remove('bookmarked');
    if (page) page   .classList.remove('bookmarked');
    ons.notification.toast('Removed from bookmarks', toastOptions);
  }

  // Save status
  const serializedStatus = (DATA[qid].visited ? 'v' : 'x') + (DATA[qid].bookmarked ? 'b' : 'x');
  localStorage.setItem(qid, serializedStatus);

  StatusUpdatedMarkerQids.push(qid);
}

// -----------------------------------------------------------------------------

// Globalize functions accessed from HTML
window.app = {

  // Page init handlers
  initMain,
  initMarkerDetails,
  initAbout,

  // Dialog button click handler
  closeFilterDialog,

  // Main menu item click handlers
  showContributing,
  showResources,
  showPrivacyPolicy,
  showAbout,

  // Map menu item click handlers
  showMarkerOnMap,
  showLocationInMapApp,
};
