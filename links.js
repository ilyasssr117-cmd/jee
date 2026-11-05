/*
 * VXTUBE download links
 * Edit only the URLs below when you publish a new build.
 * Keep this file in the same folder as index.html.
 */
(function () {
  "use strict";

  const DOWNLOAD_LINKS = {
    android: "https://store-eu-par-13.gofile.io/download/web/8c1447fb-1731-4187-96c8-5c6e878f9b98/VXTUBE.apk",
    ios: "https://store4.gofile.io/download/web/965ea0b5-3139-48f7-8f41-9e9212ea6bf7/VXTUBE.ipa",
    windows: "https://store-eu-par-8.gofile.io/download/web/a35876b4-c4ac-49b7-aadd-530778b49202/VXTUBE.rar"
  };

  const BUTTONS = {
    android: "download-android",
    ios: "download-ios",
    windows: "download-windows"
  };

  function applyDownloadLinks() {
    Object.entries(BUTTONS).forEach(([platform, elementId]) => {
      const button = document.getElementById(elementId);
      const url = DOWNLOAD_LINKS[platform];
      if (!button || typeof url !== "string" || !/^https?:\/\//i.test(url)) return;
      button.href = url.trim();
      button.target = "_blank";
      button.rel = "noopener noreferrer";
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", applyDownloadLinks, { once: true });
  } else {
    applyDownloadLinks();
  }
})();
