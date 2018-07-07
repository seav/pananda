'use strict';

const LANGUAGE_NAME          = {
                                 'en' : 'English',
                                 'tl' : 'Tagalog',
                                 'ceb': 'Cebuano',
                                 'ilo': 'Ilocano',
                                 'pam': 'Kapampangan',
                                 'es' : 'Spanish',
                                 'de' : 'German',
                                 'fr' : 'French',
                               };
const ORDERED_LANGUAGES      = ['en', 'tl', 'ceb', 'ilo', 'pam', 'es', 'de', 'fr'];
const DEGREE_LENGTH          = 110.96;  // kilometers, adjusted
const DISTANCE_FILTERS       = [1, 2, 5, 10, 20, 50, 100];  // kilometers
const TILE_LAYER_URL         = 'https://cartodb-basemaps-{s}.global.ssl.fastly.net/rastertiles/voyager_labels_under/{z}/{x}/{y}{r}.png';
const TILE_LAYER_ATTRIBUTION = 'Base map &copy; OSM (data), CARTO (style)';
const TILE_LAYER_MAX_ZOOM    = 19;
const MIN_PH_LAT             =   4.5;  // degrees
const MAX_PH_LAT             =  21.0;  // degrees
const MIN_PH_LON             = 116.5;  // degrees
const MAX_PH_LON             = 126.5;  // degrees
const GPS_ZOOM_LEVEL         = 12;
const CARD_WIDTH             = Math.floor($(window).width() - 48);  // pixels
const PHOTO_MAX_WIDTH        = CARD_WIDTH - 16;  // pixels
const THUMBNAIL_URL_TEMPLATE = 'https://upload.wikimedia.org/wikipedia/commons/thumb/{hash}/{filename}/{width}px-{filename}';
const PROGRESS_MAX_VAL       = 339.292;
const CHUNK_LENGTH           = 50;   // pixels
const SEARCH_DELAY           = 500;  // milliseconds

// Global static helper objects
var OnsNavigator;
var Map;
var Cluster;
var GpsMarker;

// Global static flags
var ImgCacheIsAvailable   = false;

// Preferences
var VisitedFilterValue;
var BookmarkedFilterValue;
var RegionFilterValue;
var DistanceFilterValue;

// Global state and status flags
var Regions               = {};
var ViewMode              = 'map';
var CurrentPosition;
var IsGeolocating         = false;
var GpsOffToastIsShown    = false;
var NumMarkersInitialized = 0;
var CurrentMarkerInfo;

initApp();

function initApp() {

  document.addEventListener('deviceready', initCordova.bind(this), false);

  // Further initialize in-memory DB
  Object.keys(DATA).forEach(function(qid) {
    let info = DATA[qid];
    info.qid = qid;
    let status = localStorage.getItem(qid);
    if (status) {
      info.visited    = status.substr(0, 1) === 'v';
      info.bookmarked = status.substr(1, 1) === 'b';
    }
    else {
      info.visited    = false;
      info.bookmarked = false;
    }
    if (typeof info.region === 'object') {
      info.region.forEach(function(value) {
        Regions[value] = true;
      });
    }
    else {
      Regions[DATA[qid].region] = true;
    }
  });

  // Initialize preferences
  VisitedFilterValue    = localStorage.getItem('visited-filter'   ) || 'any';
  BookmarkedFilterValue = localStorage.getItem('bookmarked-filter') || 'any';
  RegionFilterValue     = localStorage.getItem('region-filter'    );
  DistanceFilterValue   = localStorage.getItem('distance-filter'  );
  if (DistanceFilterValue) DistanceFilterValue = parseInt(DistanceFilterValue);
}

function initCordova() {
  screen.orientation.lock('portrait');
  if (cordova.platformId == 'android') {
    StatusBar.backgroundColorByHexString("#123");
  }
  ImgCache.options.skipURIencoding = true;
  if (cordova.file.externalCacheDirectory) {
    ImgCache.options.cordovaFilesystemRoot = cordova.file.externalCacheDirectory;
  }
  else {
    ImgCache.options.cordovaFilesystemRoot = cordova.file.dataDirectory;
  }
  ImgCache.init(function() { ImgCacheIsAvailable = true });
}

function initMain() {
  OnsNavigator = $('#navigator')[0];
  $('#view-mode-button').click(toggleView);
  $('ons-toolbar-button[icon="md-filter-list"]').click(showFilterDialog);
  $('ons-toolbar-button[icon="md-more-vert"  ]').click(showMainMenu    );
  initMap();
  if ('splashscreen' in navigator) navigator.splashscreen.hide();
  generateMapMarkers();
  initList();
  initFilterDialog();
  $('#explore').on(
    'initfinished',
    function() {
      $('#init-progress')[0].setAttribute('stroke-dashoffset', 0);
      $('#init-progress').fadeOut();
      if (DistanceFilterValue) {
        applyFilters(true);
        geolocateUser();
      }
      else {
        applyFilters();
      }
    },
  );
};

function initMap() {

  let bg = $('#explore .page__background');
  $('#map').width (bg.width ());
  $('#map').height(bg.height());

  // Create map and set initial view
  Map = new L.map('map', {attributionControl: false});
  L.control.attribution({prefix: false}).addTo(Map);
  Map.fitBounds([[MAX_PH_LAT, MAX_PH_LON], [MIN_PH_LAT, MIN_PH_LON]]);

  // Add geolocation button
  let locButton = L.control({ position: 'topleft'});
  locButton.onAdd = function() {
    let controlDiv = L.DomUtil.create('div', 'leaflet-bar leaflet-control');
    $(controlDiv).append('<a id="gps-button"><ons-icon icon="md-gps-dot"></ons-icon></a>');
    $(controlDiv).click(geolocateUser);
    return controlDiv;
  };
  locButton.addTo(Map);

  // Add tile layer
  new L.tileLayer(
    TILE_LAYER_URL,
    {
      attribution : TILE_LAYER_ATTRIBUTION,
      maxZoom     : TILE_LAYER_MAX_ZOOM,
    },
  ).addTo(Map);
}

function generateMapMarkers() {

  // Initialize the map marker cluster
  Cluster = new L.markerClusterGroup({
    maxClusterRadius: function(z) {
      if (z <=  15) return 50;
      if (z === 16) return 40;
      if (z === 17) return 30;
      if (z === 18) return 20;
      if (z >=  19) return 10;
    },
    showCoverageOnHover: false,
  }).addTo(Map);

  let qids = Object.keys(DATA);
  let numMarkers = qids.length;
  let progressElem = $('#init-progress-bar')[0];

  let processChunk = function(startIdx) {

    let idx = startIdx;
    for (; idx < numMarkers && idx < startIdx + CHUNK_LENGTH; idx++) {

      let qid = qids[idx];
      let info = DATA[qid];

      let mapMarker = L.marker(
        [info.lat, info.lon],
        { icon: L.ExtraMarkers.icon({ icon: '', markerColor : 'cyan' }) },
      );
      info.mapMarker = mapMarker;

      let popupContent = $(
        '<div class="popup-wrapper' +
          (info.visited    ? ' visited'    : '') +
          (info.bookmarked ? ' bookmarked' : '') +
        '">' +
          '<div class="popup-title">' + info.name + '</div>' +
          '<span data-qid="' + qid + '" data-action="visited"      class="zmdi zmdi-eye-off"         ></span>' +
          '<span data-qid="' + qid + '" data-action="unvisited"    class="zmdi zmdi-eye"             ></span>' +
          '<span data-qid="' + qid + '" data-action="bookmarked"   class="zmdi zmdi-bookmark-outline"></span>' +
          '<span data-qid="' + qid + '" data-action="unbookmarked" class="zmdi zmdi-bookmark"        ></span>' +
          '<ons-button data-qid="' + qid + '" modifier="quiet">Details</ons-button>' +
        '</div>'
      );
      mapMarker.bindPopup(popupContent[0], { closeButton: false });

      let popup = mapMarker.getPopup();
      info.popup = popup;

      NumMarkersInitialized++;
    }

    let progress = NumMarkersInitialized / numMarkers / 2;
    progressElem.setAttribute('stroke-dashoffset', PROGRESS_MAX_VAL * (1 - progress));
    if (idx + 1 <= numMarkers) {
      setTimeout(function() { processChunk(idx) }, 17);
    }
    else {
      if (NumMarkersInitialized === numMarkers * 2) $('#explore').trigger('initfinished');
    }
  };
  processChunk(0);

  // Event delegation
  $('#map').click(function(e) {
    let clickedElem = e.target;
    if (clickedElem.tagName === 'SPAN' && ('action' in clickedElem.dataset)) {
      e.stopPropagation();
      updateStatus(clickedElem.dataset.qid, clickedElem.dataset.action);
    }
    else if (clickedElem.tagName === 'ONS-BUTTON') {
      e.stopPropagation();
      OnsNavigator.pushPage('details.html', { data: { info: DATA[clickedElem.dataset.qid] } });
    }
  });
}

function initList() {

  let bg = $('#explore .page__background');
  $('#main-list').width (bg.width ());
  $('#main-list').height(bg.height());

  let searchInputTimeoutId;
  $('#main-list ons-search-input input').on(
    'input',
    function() {
      clearTimeout(searchInputTimeoutId);
      searchInputTimeoutId = setTimeout(applySearch, SEARCH_DELAY);
    },
  );
  $('#missing-info-notice ons-button').click(showContributing);

  let qids = Object.keys(DATA);
  let numMarkers = qids.length;
  let listItems = [];
  let progressElem = $('#init-progress-bar')[0];
  let list = $('#main-list ons-list');

  let processChunk = function(startIdx) {

    let idx = startIdx;
    for (; idx < numMarkers && idx < startIdx + CHUNK_LENGTH; idx++) {

      let qid = qids[idx];
      let info = DATA[qid];
      let li = $(
        '<ons-list-item data-qid="' + qid + '" class="' +
          (info.visited    ? ' visited'    : '') +
          (info.bookmarked ? ' bookmarked' : '') +
        '">' +
          '<div class="center">' +
            '<div class="name">' + info.name + '</div>' +
            '<div class="address">' + info.macroAddress + '</div>' +
            '<div class="distance"></div>' +
          '</div>' +
          '<div class="right">' +
            '<span data-qid="' + qid + '" data-action="visited"      class="zmdi zmdi-eye-off"         ></span>' +
            '<span data-qid="' + qid + '" data-action="unvisited"    class="zmdi zmdi-eye"             ></span>' +
            '<span data-qid="' + qid + '" data-action="bookmarked"   class="zmdi zmdi-bookmark-outline"></span>' +
            '<span data-qid="' + qid + '" data-action="unbookmarked" class="zmdi zmdi-bookmark"        ></span>' +
          '</div>' +
        '</ons-list-item>'
      );
      info.mainListItem = li[0];
      listItems.push(li);

      NumMarkersInitialized++;
    }

    let progress = NumMarkersInitialized / numMarkers / 2;
    progressElem.setAttribute('stroke-dashoffset', PROGRESS_MAX_VAL * (1 - progress));
    if (idx + 1 <= numMarkers) {
      setTimeout(function() { processChunk(idx) }, 17);
    }
    else {
      list.append(listItems);
      if (NumMarkersInitialized === numMarkers * 2) $('#explore').trigger('initfinished');
    }
  }
  processChunk(0);

  // Event delegation
  list.click(function(e) {
    let clickedElem = e.target;
    if (clickedElem.tagName === 'SPAN' && ('action' in clickedElem.dataset)) {
      updateStatus(clickedElem.dataset.qid, clickedElem.dataset.action);
    }
    else {
      while (!('qid' in clickedElem.dataset)) clickedElem = clickedElem.parentElement;
      OnsNavigator.pushPage('details.html', { data: { info: DATA[clickedElem.dataset.qid] } });
    }
  });
}

function initFilterDialog() {

  let select;

  select = $('<ons-select id="region-filter"></ons-select>');
  select.append('<option val="0">any region</option>');
  Object.keys(Regions).sort(function(a, b) {
    if (a < b) return -1;
    if (a > b) return  1;
    return 0;
  }).forEach(function(value) {
    select.append('<option val="' + value + '"' + (RegionFilterValue === value ? ' selected' : '') + '>' + value + '</option>');
  });
  $('#region-filter-wrapper').append(select);

  select = $('<ons-select id="distance-filter"></ons-select>');
  select.append('<option val="0">any distance</option>');
  DISTANCE_FILTERS.forEach(function(value) {
    select.append('<option val="' + value + '"' + (DistanceFilterValue === value ? ' selected' : '') + '>within ' + value + ' km</option>');
  });
  $('#distance-filter-wrapper').append(select);
}

function toggleView() {
  if (ViewMode === 'map') showList();
  else                    showMap();
}

function showMap() {
  ViewMode = 'map';
  $('#explore ons-toolbar .left').text('Map view');
  $('#view-mode-button').attr('icon', 'md-view-list');
  $('#map').css('z-index', 1);
  $('#map').css('opacity', 1);
  $('#main-list').css('z-index', 0);
  $('#main-list').css('opacity', 0);
}

function showList() {
  ViewMode = 'list';
  $('#explore ons-toolbar .left').text('List view');
  $('#view-mode-button').attr('icon', 'md-map');
  $('#main-list').css('z-index', 1);
  $('#main-list').css('opacity', 1);
  $('#map').css('z-index', 0);
  $('#map').css('opacity', 0);
}

function geolocateUser() {

  if (IsGeolocating) return;
  let gpsButton = $('#gps-button ons-icon')[0];

  let stopGeolocatingUi = function() {
    IsGeolocating = false;
    gpsButton.setAttribute('icon', 'md-gps-dot');
    gpsButton.removeAttribute('spin');
  };

  // Inner core function
  let getAndProcessLocation = function() {
    navigator.geolocation.getCurrentPosition(
      function(position) {
        stopGeolocatingUi();
        // Invalidate all distances
        Object.keys(DATA).forEach(function(qid) {
          DATA[qid].distance = null;
        });
        CurrentPosition = {
          lat: position.coords.latitude,
          lon: position.coords.longitude,
        };
        if (!GpsMarker) {
          let icon = L.icon({
            iconUrl    : 'img/red-marker.svg',
            iconSize   : [24, 24],
            iconAnchor : [12, 12],
          });
          GpsMarker = L.marker(CurrentPosition, {icon: icon}).addTo(Map);
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
      },
      function() {
        stopGeolocatingUi();
        ons.notification.toast(
          'Cannot get GPS location',
          {
            force       : true,
            buttonLabel : 'OK',
          },
        );
      },
      {
        timeout    : 60000,
        maximumAge : 60000,
      },
    );
  };

  let startGeolocatingUi = function() {
    IsGeolocating = true;
    ons.notification.toast('Getting GPS location...', { timeout: 1000 });
    gpsButton.setAttribute('icon', 'md-spinner');
    gpsButton.setAttribute('spin', 'spin');
    setTimeout(getAndProcessLocation, 200);
  };

  // Wrapper logic to check if GPS is enabled
  if (typeof gpsDetect !== 'undefined') {
    gpsDetect.checkGPS(
      function(gpsIsEnabled) {
        if (gpsIsEnabled) {
          startGeolocatingUi();
        }
        else {
          if (!GpsOffToastIsShown) {
            GpsOffToastIsShown = true;
            let promise = ons.notification.toast('You need to turn GPS on first', { timeout: 2000 });
            promise.then(function() { GpsOffToastIsShown = false });
          }
        }
      },
      startGeolocatingUi,
    );
  }
  else {
    startGeolocatingUi();
  }
}

function applySearch() {

  // Prepare query
  let query = $('#main-list ons-search-input input')[0].value;
  query = query.replace(/^\s+|\s+$/g, '');  // Remove trailing spaces
  query = query.replace(/[[\]{}()*+!<=:?\/\\^$|#,@]/g, '');  // Remove some punctuation
  query = query.replace(/\./g, '\\$&');  // Escape periods
  let terms = query.split(/\s+/);
  let regex = new RegExp(terms.map(x => '(?=.*' + x + ')').join(''), 'i');

  // Perform search filtering
  let numPotentialResults = 0;
  let numActualResults    = 0;
  Object.values(DATA).forEach(function(info) {
    if (!info.filtered) return;
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
    let msg = $('#search-results-msg');
    if (numActualResults === 0) {
      msg.text('No results');
    }
    else {
      msg.text('Showing ' + numActualResults + ' result' + (numActualResults > 1 ? 's' : '') + ' out of ' + numPotentialResults);
    }
    msg.show();
    if (numActualResults === 0) {
      $('#missing-info-notice').show();
    }
    else {
      $('#missing-info-notice').hide();
    }
  }
  else {
    $('#search-results-msg').hide();
    $('#missing-info-notice').hide();
  }
}

function showFilterDialog() {

  let setRadioButtons = function() {
    let vRadios = $('ons-radio[name="visited-option"]');
    let bRadios = $('ons-radio[name="bookmarked-option"]');
    [0, 1, 2].forEach(function(i) {
      if (VisitedFilterValue    === vRadios[i].value) vRadios[i].checked = true;
      if (BookmarkedFilterValue === bRadios[i].value) bRadios[i].checked = true;
    });
  };

  let dialog = document.getElementById('filter-dialog');
  dialog.show();
  setRadioButtons();
}

function closeFilterDialog() {

  let prevVisited    = VisitedFilterValue;
  let prevBookmarked = BookmarkedFilterValue;
  let prevRegion     = RegionFilterValue;
  let prevDistance   = DistanceFilterValue;

  // Update filter values
  let vRadios = $('ons-radio[name="visited-option"]');
  let bRadios = $('ons-radio[name="bookmarked-option"]');
  [0, 1, 2].forEach(function(i) {
    if (vRadios[i].checked) VisitedFilterValue    = vRadios[i].value;
    if (bRadios[i].checked) BookmarkedFilterValue = bRadios[i].value;
  });
  let onsSelect = $('#region-filter')[0];
  RegionFilterValue = onsSelect.selectedIndex === 0 ? null : onsSelect.value;
  let index = $('#distance-filter')[0].selectedIndex;
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
    $('#main-list ons-search-input input')[0].value = '';
    applyFilters();
  }

  $('#filter-dialog')[0].hide();
}

function applyFilters(suppressToast) {

  // Determine which markers are visible and show/hide map markers
  // and main list items accordingly
  let visibleQids = [];
  let visibleMapMarkers = [];
  Object.keys(DATA).forEach(function(qid) {
    let info = DATA[qid];
    if (
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
    ) {
      visibleQids.push(qid);
      visibleMapMarkers.push(info.mapMarker);
      $(info.mainListItem).show();
      info.filtered = true;
    }
    else {
      $(info.mainListItem).hide();
      info.filtered = false;
    }
  });
  Cluster.clearLayers();
  Cluster.addLayers(visibleMapMarkers);

  // Sort main list either by distance or alphabetically
  let list = document.querySelector('#main-list ons-list');
  if (DistanceFilterValue && CurrentPosition) {
    list.classList.remove('sorted-alphabetically');
    visibleQids.sort(function(a, b) {
      return DATA[a].distance - DATA[b].distance;
    });
  }
  else {
    list.classList.add('sorted-alphabetically');
    visibleQids.sort(function(a, b) {
      if (DATA[a].name < DATA[b].name) return -1;
      if (DATA[a].name > DATA[b].name) return  1;
      return 0;
    });
  }
  visibleQids.forEach(function(qid) {
    list.removeChild(DATA[qid].mainListItem);
    list.appendChild(DATA[qid].mainListItem);
  });

  // If the distance filter has kicked in because of a delay in getting
  // the GPS location, we need to re-apply the search
  applySearch();

  // Show toast message as needed
  let numFiltered = visibleQids.length;
  if (!suppressToast && numFiltered > 0) {
    ons.notification.toast(
      'Now showing ' + numFiltered + ' marker' + (numFiltered > 1 ? 's' : ''),
      { timeout: 2000 },
    );
  }
  if (numFiltered === 0) {
    ons.notification.toast('No markers match the filters', { timeout: 2000 });
  }
}

function isMarkerNear(info) {
  let maxDegreeDiff = 2 * DistanceFilterValue / DEGREE_LENGTH;  // Double to adjust for higher latitudes
  if (Math.abs(info.lat - CurrentPosition.lat) > maxDegreeDiff) return false;
  if (Math.abs(info.lon - CurrentPosition.lon) > maxDegreeDiff) return false;
  if (!info.distance) computeDistanceToMarker(info);
  return info.distance <= DistanceFilterValue * 1000;
}

function computeDistanceToMarker(info) {

  // Uses a simple Euclidean formula for faster calculation
  let x =  CurrentPosition.lat - info.lat;
  let y = (CurrentPosition.lon - info.lon) * Math.cos(CurrentPosition.lat * Math.PI / 180);
  let distance = Math.round(DEGREE_LENGTH * 1000 * Math.sqrt(x * x + y * y));
  info.distance = distance;

  // Generate UI distance string (generally 2 significant figures)
  let distanceLabel;
  if (distance <= 100) {
    distanceLabel = distance + ' m';
  }
  else if (distance <= 1000) {
    distanceLabel = (Math.round(distance / 10) * 10) + ' m';
  }
  else if (distance <= 10000) {
    distanceLabel = (Math.round(distance / 100) / 10) + ' km';
  }
  else {
    distanceLabel = (Math.round(distance / 1000)) + ' km';
  }
  info.mainListItem.querySelector('.distance').innerHTML = distanceLabel;
}

function showMainMenu() {
  let button = $('ons-toolbar-button[icon="md-more-vert"  ]')[0];
  let menu = document.getElementById('main-menu');
  menu.show(button);
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

function initMarkerDetails() {

  let info = this.data.info;
  CurrentMarkerInfo = info;

  // Filters are applied when going back because the user
  // may have updated the visited/bookmarked status
  $('ons-back-button').click(function() { applyFilters(true) });

  // Activate status buttons
  // ------------------------------------------------------

  let page = $('#details');
  if (info.visited   ) page.addClass('visited'   );
  if (info.bookmarked) page.addClass('bookmarked');

  let notVisitedButton    = $('ons-toolbar-button[icon="md-eye-off"         ]');
  let visitedButton       = $('ons-toolbar-button[icon="md-eye"             ]');
  let notBookmarkedButton = $('ons-toolbar-button[icon="md-bookmark-outline"]');
  let bookmarkedButton    = $('ons-toolbar-button[icon="md-bookmark"        ]');
  notVisitedButton   .click(function() { updateStatus(info.qid, 'visited'     ) });
  visitedButton      .click(function() { updateStatus(info.qid, 'unvisited'   ) });
  notBookmarkedButton.click(function() { updateStatus(info.qid, 'bookmarked'  ) });
  bookmarkedButton   .click(function() { updateStatus(info.qid, 'unbookmarked') });

  // Prepare header
  // ------------------------------------------------------

  let top = $(this).find('#details-content');

  let header = $('<header class="marker"></header>');
  header.append('<h1>' + info.name + '</h1>');
  if (info.date !== true) header.append(generateMarkerDateElem(info.date));
  top.append(header);

  // Construct card for marker details
  // ------------------------------------------------------

  let card = $('<ons-card></ons-card>');
  top.append(card);

  // Default is plaque(s) is monolingual
  let l10nData = info.details;
  let plaqueIsMonolingual = true;

  // Adjust if plaque is multilingual
  if ('photo' in info.details) {
    l10nData = info.details.text;
    plaqueIsMonolingual = false;
  }

  // Add photo for multilingual plaque
  if (!plaqueIsMonolingual) {
    card.append(generateFigureElem(info.details.photo));
  }

  let langCodes = $.grep(ORDERED_LANGUAGES, x => l10nData[x]);

  let segment = $('<div class="segment segment--material"></div>');
  if (langCodes.length === 1) segment.addClass('single');
  card.append(segment);
  langCodes.forEach(function(code, index) {

    // Add language to segment
    let segmentItem = $(
      '<div class="segment__item segment--material__item">' +
      '<input type="radio" class="segment__input segment--material__input" name="segment-lang"' +
      (index === 0 ? ' checked' : '') +
      '><div class="segment__button segment--material__button">' +
      LANGUAGE_NAME[code] +
      '</div>'
    );
    segmentItem.click(function() {
      $('.marker-text.' + code).addClass('active');
      $('.marker-text:not(.' + code + ')').removeClass('active');
      if (info.date === true) {
        $('.marker-date.' + code).addClass('active');
        $('.marker-date:not(.' + code + ')').removeClass('active');
      }
      $('.marker-figure.' + code).addClass('active');
      $('.marker-figure:not(.' + code + ')').removeClass('active');
    });
    segment.append(segmentItem);

    // Process differing dates
    if (info.date === true) {
      let div = generateMarkerDateElem(l10nData[code].date);
      div.addClass(code);
      if (index === 0) div.addClass('active');
      card.append(div);
    }

    // Add photo for monolingual plaque
    if (plaqueIsMonolingual) {
      let figure = generateFigureElem(l10nData[code].photo);
      figure.addClass('marker-figure');
      figure.addClass(code);
      if (index === 0) figure.addClass('active');
      card.append(figure);
    }

    // Process text
    let textData = (plaqueIsMonolingual ? l10nData[code].text : l10nData[code]);
    let textDiv = $('<div class="marker-text ' + code + (index === 0 ? ' active' : '') + '"></div>');
    if (textData.title) {
      textDiv.append('<h2>' + textData.title + '</h2>');
      if (textData.subtitle) textDiv.append('<h3>' + textData.subtitle + '</h3>');
    }
    if (textData.inscription === '') {
      textDiv.append('<p class="nodata">No inscription encoded yet.</p>');
    }
    else if (textData.inscription !== null) {
      textDiv.append(textData.inscription);
    }
    card.append(textDiv);
  });

  // Add Wikipedia links
  if (info.wikipedia) {
    let linksDiv = $('<div class="wikipedia-links"><h3>Learn more on Wikipedia</h3></div>');
    Object.keys(info.wikipedia).forEach(function(title) {
      let urlPath = info.wikipedia[title] === true ? title : info.wikipedia[title];
      let linkP = $('<p><a target="_system" href="https://en.wikipedia.org/wiki/' + escape(urlPath) + '">' + title + '</a></p>');
      linksDiv.append(linkP);
    });
    card.append(linksDiv);
  }

  // Construct card for marker location
  // ------------------------------------------------------

  card = $('<ons-card class="location"></ons-card>');
  top.append(card);

  let button = $('<ons-button><ons-icon icon="md-more-vert"></ons-icon></ons-button>');
  button.click(function(evt) {
    let menu = document.getElementById('loc-menu');
    menu.show(evt);
  });
  card.append(button);

  if (info.address ) card.append('<p><strong>Address:</strong> ' + info.address);
  if (info.locDesc ) card.append('<p><strong>Location description:</strong> ' + info.locDesc);
  if (info.locPhoto) card.append(generateFigureElem(info.locPhoto));
};

function generateMarkerDateElem(dateString) {
  let text;
  if (!dateString) {
    text = 'Unveiling date unknown';
  }
  else if (dateString.length === 4) {
    text = 'Unveiled in ' + dateString;
  }
  else {
    let date = new Date(dateString);
    text = 'Unveiled on ' + date.toLocaleDateString(
      'en-US',
      {
        month: 'long',
        day: 'numeric',
        year: 'numeric',
      },
    );
  }
  return $('<div class="marker-date"><ons-icon icon="md-calendar"></ons-icon> ' + text + '</div>');
}

function generateFigureElem(photoData) {

  let figure = $('<figure></figure>');

  if (photoData) {

    let width = photoData.width >= photoData.height ? PHOTO_MAX_WIDTH : PHOTO_MAX_WIDTH / photoData.height * photoData.width;
    let height = width / photoData.width * photoData.height;
    let url = THUMBNAIL_URL_TEMPLATE.replace('{hash}', photoData.hash.substr(0, 1) + '/' + photoData.hash.substr(0, 2));
    url = url.replace('{width}', Math.floor(width) * 2);
    url = url.replace(/\{filename\}/g, photoData.file.replace(/ /g, '_'));

    let placeholder = $('<div class="placeholder"></div>');
    placeholder.width(width);
    placeholder.height(height);
    figure.append(placeholder);
    figure.append('<figcaption>' + photoData.credit + '</figcaption>');

    if (ImgCacheIsAvailable) {
      // TODO: Implement cache validation
      ImgCache.isCached(
        url,
        function(path, success) {
          if (success) {
            ImgCache.getCachedFileURL(
              url,
              function(url, path) {
                replaceFigurePlaceholder(placeholder, path, width, height);
              },
              function() {
                replaceFigurePlaceholder(placeholder, url, width, height);
              },
            );
          }
          else {
            ImgCache.cacheFile(
              url,
              function () {
                ImgCache.getCachedFileURL(
                  url,
                  function(url, path) {
                    replaceFigurePlaceholder(placeholder, path, width, height);
                  },
                  function() {
                    replaceFigurePlaceholder(placeholder, url, width, height);
                  },
                );
              },
              function() {
                replaceFigurePlaceholder(placeholder, url, width, height);
              },
            );
          }
        },
      );
    }
    else {
      replaceFigurePlaceholder(placeholder, url, width, height);
    }
  }

  // No actual photo
  else {
    figure.addClass('nodata');
    let padding = Math.floor(CARD_WIDTH / 5);
    figure.css('padding', padding + 'px 16px');
    figure.append('<div>No photo available yet</div>');
    let button = $('<ons-button>Contribute</ons-button>');
    button.click(showContributing);
    figure.append(button);
  }

  return figure;
}

function replaceFigurePlaceholder(placeholder, src, width, height) {
  placeholder.replaceWith('<img src="' + src + '" width="' + width +'" height="' + height + '">');
}

function showMarkerOnMap() {
  document.getElementById('loc-menu').hide();
  showMap();
  OnsNavigator.popPage({
    animation : 'slide',
    callback  : function() {
      Cluster.zoomToShowLayer(
        CurrentMarkerInfo.mapMarker,
        function() {
          Map.panTo([CurrentMarkerInfo.lat, CurrentMarkerInfo.lon]);
          if (!CurrentMarkerInfo.popup.isOpen()) {
            CurrentMarkerInfo.mapMarker.openPopup();
          }
        },
      );
    },
  });
}

function showLocationInMapApp() {
  document.getElementById('loc-menu').hide();
  window.open('geo:' + CurrentMarkerInfo.lat + ',' + CurrentMarkerInfo.lon + '?z=20');
}

function updateStatus(qid, status) {

  let info = DATA[qid];
  let page = document.getElementById('details');

  // Update internal DB and button states and show toast
  let toastOptions = {
    timeout : 1000,
    force   : true,
  };
  if (status === 'visited') {
    info.visited = true;
    info.mainListItem  .classList.add('visited');
    info.popup._content.classList.add('visited');
    if (page) page     .classList.add('visited')
    ons.notification.toast('Marked as visited', toastOptions);
  }
  else if (status === 'unvisited') {
    info.visited = false;
    info.mainListItem  .classList.remove('visited');
    info.popup._content.classList.remove('visited');
    if (page) page     .classList.remove('visited');
    ons.notification.toast('Marked as not visited', toastOptions);
  }
  else if (status === 'bookmarked') {
    info.bookmarked = true;
    info.mainListItem  .classList.add('bookmarked');
    info.popup._content.classList.add('bookmarked');
    if (page) page     .classList.add('bookmarked');
    ons.notification.toast('Added to bookmarks', toastOptions);
  }
  else { // status === 'unbookmarked'
    info.bookmarked = false;
    info.mainListItem  .classList.remove('bookmarked');
    info.popup._content.classList.remove('bookmarked');
    if (page) page     .classList.remove('bookmarked');
    ons.notification.toast('Removed from bookmarks', toastOptions);
  }

  // Save status
  let serializedStatus = (DATA[qid].visited ? 'v' : 'x') + (DATA[qid].bookmarked ? 'b' : 'x');
  localStorage.setItem(qid, serializedStatus);
}
