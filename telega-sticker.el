;;; telega-sticker.el --- Stickers for the telega

;; Copyright (C) 2019 by Zajcev Evgeny.

;; Author: Zajcev Evgeny <zevlg@yandex.ru>
;; Created: Fri Feb  8 21:08:24 2019
;; Keywords:

;; telega is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; telega is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with telega.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:
(require 'telega-core)
(require 'telega-util)

(defcustom telega-sticker-height 4
  "*Height of stickers in char heights."
  :type 'integer
  :group 'telega)

(defvar telega-sticker-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map [remap self-insert-command] 'ignore)
    (define-key map (kbd "f") 'telega-sticker-toggle-favorite)
    (define-key map (kbd "*") 'telega-sticker-toggle-favorite)
    (define-key map (kbd "i") 'telega-sticker-help)
    (define-key map (kbd "h") 'telega-sticker-help)
    map))

(define-button-type 'telega-sticker
  :supertype 'telega
  :inserter 'telega-ins--sticker
;  'read-only t
  'keymap telega-sticker-button-map)

(defun telega-sticker-at (&optional pos)
  "Retur sticker at POS."
  (let ((button (button-at (or pos (point)))))
    (when (and button (eq (button-type button) 'telega-sticker))
      (button-get button :value))))

(defsubst telega-sticker-get (file-id)
  (telega--getFile file-id))

(defun telega-sticker-favorite-p (sticker)
  "Return non-nil if STICKER is in favorite list."
  (cl-find (telega--tl-get sticker :sticker :id)
           telega--stickers-favorite
           :key (telega--tl-prop :id)
           :test 'eq))

(defun telega-file--ensure-downloaded (sfile files-list)
  (cl-assert (memq sfile files-list))
  (when (telega-media--need-download-p sfile)
    (telega-file--download-monitor-progress (plist-get sfile :id)
      (lambda (file slist)
        (let ((stail (cl-member (plist-get file :id) slist
                                :key (telega--tl-prop :id))))
          (cl-assert stail)
          (setcar stail file)))
      files-list)
    (telega--downloadFile (plist-get sfile :id))))

(defun telega-sticker--ensure-downloaded (sticker)
  "Ensure STICKER data is downloaded."
  (let ((sthumb (plist-get sticker :thumbnail)))
    (when (telega-media--need-download-p (plist-get sthumb :photo))
      (telega-file--download-monitoring sthumb :photo))
    (when (telega-media--need-download-p (plist-get sticker :sticker))
      (telega-file--download-monitoring sticker :sticker))
    ))

(defun telega-stickerset--ensure-downloaded (sset)
  "Ensure sticker set SSET data is downloaded."
  (mapc 'telega-sticker--ensure-downloaded (plist-get sset :stickers)))

(defun telega--getStickerSet (set-id &optional callback)
  (telega-server--call
   (list :@type "getStickerSet"
         :set_id set-id)
   callback))

(defun telega-stickerset--ensure (sset)
  "Ensure sticker set SSET is put into `telega--stickersets'."
  (setf (alist-get (plist-get sset :id) telega--stickersets nil nil 'equal)
        sset)
  (telega-stickerset--ensure-downloaded sset)
  sset)

(defun telega-stickerset-get (set-id &optional async-p)
  (let ((sset (cdr (assoc set-id telega--stickersets))))
    (unless sset
      (if async-p
          (telega--getStickerSet set-id 'telega-stickerset--ensure)

        (setq sset (telega--getStickerSet set-id))
        (telega-stickerset--ensure sset)))
    sset))

(defun telega--on-updateInstalledStickerSets (event)
  "The list of installed sticker sets was updated."
  (if (plist-get event :is_masks)
      (telega-debug "TODO: `telega--on-updateInstalledStickerSets' is_mask=True")

    ;; Asynchronously fetch sticker sets
    (setq telega--stickersets-installed-ids
          (mapcar 'identity (plist-get event :sticker_set_ids)))
    (cl-dolist (set-id telega--stickersets-installed-ids)
      (telega-stickerset-get set-id 'async))
    ))

(defun telega--on-updateTrendingStickerSets (event)
  "The list of trending sticker sets was updated or some of them were viewed."
  (let ((ssets-info (telega--tl-get event :sticker_sets :sets)))
    (setq telega--stickersets-trending
          (mapcar 'identity ssets-info))))

(defun telega--on-updateRecentStickers (event)
  "Recent stickers has been updated."
  ;; NOTE: attached recent stickers are not supported
  (unless (plist-get event :is_attached)
    (setq telega--stickers-recent nil)

    ;; Asynchronously download corresponding files
    (seq-doseq (sid (plist-get event :sticker_ids))
      (telega--getFile sid
        (lambda (sfile)
          (push sfile telega--stickers-recent)
          (telega-file--ensure-downloaded
           sfile telega--stickers-recent))))))

(defun telega--on-updateFavoriteStickers (event)
  "Favorite stickers has been updated."
  (setq telega--stickers-favorite nil)

  ;; Asynchronously download corresponding files
  (seq-doseq (sid (plist-get event :sticker_ids))
    (telega--getFile sid
      (lambda (sfile)
        (push sfile telega--stickers-favorite)
        (telega-file--ensure-downloaded
         sfile telega--stickers-favorite)))))

(defun telega--getStickers (emoji &optional limit callback)
  "Return installed stickers that correspond to a given EMOJI.
LIMIT defaults to 20."
  (let ((reply (telega-server--call
                (list :@type "getStickers"
                      :emoji emoji
                      :limit (or limit 20))
                callback)))
    (mapcar 'identity (plist-get reply :stickers))))

(defun telega--searchStickers (emoji &optional limit callback)
  "Search for the public stickers that correspond to a given EMOJI.
LIMIT defaults to 20."
  (let ((reply (telega-server--call
                (list :@type "searchStickers"
                      :emoji emoji
                      :limit (or limit 20))
                callback)))
    (mapcar 'identity (plist-get reply :stickers))))

(defun telega--getInstalledStickerSets (&optional masks-p)
  "Returns a list of installed sticker sets."
  (cl-assert (not masks-p) t "installed masks not yet supported")

  (let ((reply (telega-server--call
                (list :@type "getInstalledStickerSets"
                      :is_masks (or masks-p :false)))))
    (mapcar 'identity (plist-get reply :sets))))

(defun telega--changeStickerSet (stickerset install-p &optional archive-p)
  "Install/Uninstall STICKERSET."
  (telega-server--call
   (list :@type "changeStickerSet"
         :set_id (plist-get stickerset :id)
         :is_installed (or install-p :false)
         :is_archived (or archive-p :false))))

(defun telega--getTrendingStickerSets ()
  "Returns a list of trending sticker sets."
  (telega-server--call
   (list :@type "getTrendingStickerSets")))

(defun telega--getAttachedStickerSets (file-id)
  "Return sticker sets attached to the FILE-ID.
Photo and Video files have attached sticker sets."
  (telega-server--call
   (list :@type "getAttachedStickerSets"
         :file_id file-id)))

(defun telega--searchStickerSet (name)
  "Search for sticker set by NAME."
  (telega-server--call
   (list :@type "searchStickerSet"
         :name name)))

(defun telega--searchInstalledStickerSets (query &optional masks-p limit)
  "Searches for installed sticker sets by QUERY."
  (telega-server--call
   (list :@type "searchInstalledStickerSets"
         :is_masks (or masks-p :false)
         :query query
         :limit (or limit 20))))

(defun telega--searchStickerSets (query)
  "Searches for ordinary sticker sets by looking for specified QUERY."
  (telega-server--call
   (list :@type "searchStickerSets")))

(defun telega--viewTrendingStickerSets (set-id &rest other-ids)
  (telega-server--call
   (list :@type "viewTrendingStickerSets"
         :sticker_set_ids (cl-map 'vector 'identity
                                  (nconc (list set-id) other-ids)))))

(defun telega--getRecentStickers (&optional attached-p)
  "Returns a list of recently used stickers.
Pass non-nil ATTACHED-P to return only stickers attached to photos/videos."
  (let ((reply (telega-server--call
                (list :@type "getRecentStickers"
                      :is_attached (or attached-p :false)))))
    (mapcar 'identity (plist-get reply :stickers))))

(defun telega--getFavoriteStickers ()
  "Return favorite stickers."
  (let ((reply (telega-server--call
                (list :@type "getFavoriteStickers"))))
    (mapcar 'identity (plist-get reply :stickers))))

(defun telega--addFavoriteSticker (sticker-input-file)
  "Add STICKER-INPUT-FILE on top of favorite stickers."
  (telega-server--call
   (list :@type "addFavoriteSticker"
         :sticker sticker-input-file)))

(defun telega--removeFavoriteSticker (sticker-input-file)
  (telega-server--call
   (list :@type "removeFavoriteSticker"
         :sticker sticker-input-file)))

(defun telega-sticker-toggle-favorite (sticker)
  "Toggle sticker as favorite."
  (interactive (list (telega-sticker-at)))
  (funcall (if (telega-sticker-favorite-p sticker)
               'telega--removeFavoriteSticker
             'telega--addFavoriteSticker)
           (list :@type "inputFileId"
                 :id (telega--tl-get sticker :sticker :id))))

(defun telega--getStickerEmojis (sticker-input-file)
  (telega-server--call
   (list :@type "getStickerEmojis"
         :sticker sticker-input-file)))

(defun telega-sticker--progress-svg (sticker)
  (let* ((progress (telega-file--downloading-progress
                    (plist-get sticker :sticker)))
         (emoji (telega--desurrogate-apply (plist-get sticker :emoji)))
         (h (* (frame-char-height) telega-sticker-height))
         (w-chars (telega-chars-in-width h))
         (w (* (telega-chars-width 1) w-chars))
         (svg (svg-create w h))
         (font-size (/ h 2))
         ;; progress clipping mask
         (angle-o (+ pi (* 2 pi (- 1.0 progress))))
         (clip-dx (* (/ w 2) (1+ (sin angle-o))))
         (clip-dy (* (/ h 2) (1+ (cos angle-o))))
         (pclip (telega-svg-clip-path svg "pclip")))

    (svg-text svg (substring emoji 0 1)
                :font-size font-size
                :font-weight "bold"
                :fill "white"
                :font-family "monospace"
                :x (/ font-size 2)
                :y (+ font-size (/ font-size 3)))

    ;; clip mask for the progress circle
    (let ((cp (format "M %d %d L %d %d L %d 0" (/ w 2) (/ h 2) (/ w 2) 0 0)))
      (when (< progress 0.75)
        (setq cp (concat cp (format " L 0 %d" h))))
      (when (< progress 0.5)
        (setq cp (concat cp (format " L %d %d" w h))))
      (when (< progress 0.25)
        (setq cp (concat cp (format " L %d 0" w))))
      (setq cp (concat cp (format " L %d %d" clip-dx clip-dy)))
      (setq cp (concat cp " Z"))
      (telega-svg-path pclip cp))
    ;; progress circle
    (svg-circle svg (/ w 2) (/ h 2) (/ h 2)
                :fill-color (face-foreground 'shadow)
                :fill-opacity "0.25"
                :clip-path "url(#pclip)")
    (svg-image svg :scale 1.0
               :ascent 'center
               ;; text of correct width
               :telega-text
               (make-string (or (plist-get sticker :telega-image-char-width)
                                w-chars)
                            ?X))
    ))

(defun telega-sticker--create-image (sticker &optional file)
  "Return image for the STICKER."
  ;; Three cases:
  ;;   1) Sticker downloaded
  ;;      Just show (and cache) sticker image
  ;;
  ;;   2) Thumbnail is downloaded, while sticker still downloading
  ;;      Show thumbnail (caching temporary), waiting for sticker to
  ;;      be downloaded
  ;;
  ;;   3) Thumbnail and sticker downloading
  ;;      Fallback to `telega-sticker--progress-svg', waiting for
  ;;      thumbnail or sticker to be downloaded
  (unless (plist-get sticker :telega-image-char-width)
    ;; Calculate resulting image width in chars
    (let ((sw (plist-get sticker :width))
          (sh (plist-get sticker :height))
          (mh (* (frame-char-height) telega-sticker-height)))
      (plist-put sticker :telega-image-char-width
                 (telega-chars-in-width (* (/ sw sh) mh)))))

  (let* ((sfile (plist-get sticker :sticker))
         (sthumb (telega--tl-get sticker :thumbnail :photo))
         (filename (or (and (telega-file--downloaded-p sfile) sfile)
                       (and (telega-file--downloaded-p sthumb) sthumb)
                       )))
    (if filename
        (apply 'create-image (telega--tl-get filename :local :path)
               'imagemagick nil
               :height (* (frame-char-height) telega-sticker-height)
               :scale 1.0
               :ascent 'center
               (when (telega-sticker-favorite-p sticker)
                 (list :relief 4)))
      ;; Fallback to svg
      (telega-sticker--progress-svg sticker))))

(defun telega-ins--sticker (sticker &optional slices-p)
  "Inserter for the STICKER.
If SLICES-P is non-nil, then insert STICKER using slices."
  (telega-ins--media-image
   (cons sticker 'telega-sticker--create-image)
   (cons sticker :sticker)
   slices-p))

(defun telega-ins--stickerset-change-button (sset)
  (telega-ins--button (if (plist-get sset :is_installed)
                          ;; I18N: XXX
                          "Uninstall"
                        "Install")
    :value sset
    'action 'telega-button--stickerset-change-action))

(defun telega-button--stickerset-change-action (button)
  (let ((sset (button-get button :value)))
    (telega--changeStickerSet sset (not (plist-get sset :is_installed)))
    ;; Update sset value, :is_installed might change
    (setq sset (telega-stickerset-get (plist-get sset :id)))
    (telega-save-cursor
      (telega-button--change button
        (telega-ins--stickerset-change-button sset)))))

(defun telega-describe-stickerset (sset &optional info-p)
  "Describe the sticker set."
  (interactive (list (telega-sticker-set-at-point)))
  (let ((stickers (plist-get sset (if info-p :covers :stickers))))
    (with-telega-help-win "*Telegram Sticker Set*"
      (telega-ins "Title: " (plist-get sset :title) " ")
      (telega-ins--stickerset-change-button sset)
      (telega-ins "\n")
      (telega-ins "Name: " (plist-get sset :name))
      (when (plist-get sset :is_official)
        (telega-ins telega-symbol-verified))
      (let ((link (concat (or (plist-get telega--options :t_me_url)
                              "https://t.me/")
                          "addstickers/" (plist-get sset :name))))
        (telega-ins " ")
        (telega-ins--raw-button (telega-link-props 'url link)
          (telega-ins link))
        (telega-ins "\n"))
      (telega-ins-fmt "%s: %d\n"
        (if (plist-get sset :is_masks) "Masks" "Stickers")
        (length stickers))
      (seq-doseq (sticker stickers)
        (when (> (telega-current-column) (- telega-chat-fill-column 10))
          (telega-ins "\n\n"))
        (telega-button--insert 'telega-sticker sticker)
        (sit-for 0)
        (telega-ins (plist-get sticker :emoji))
        (telega-ins "  "))
      )))


;; Choosing sticker by emoji
(defvar telega-help-win--emoji nil
  "Emoji for which help window is displayed.")
(make-variable-buffer-local 'telega-help-win--emoji)

(defun telega-sticker--choosen-action (button)
  "Execute action when sticker BUTTON is pressed."
  (cl-assert telega--chat)
  (cl-assert (eq major-mode 'help-mode))
  (let ((sticker (telega-sticker-at button)))
    (with-telega-chatbuf telega--chat
      ;; Substitute emoji with sticker, in case help win has
      ;; `telega-help-win--emoji' set
      (when telega-help-win--emoji
        (let* ((input (telega-chatbuf-input-string))
               (emoji (and (> (length input) 0) (substring input 0 1))))
          (unless (string= emoji telega-help-win--emoji)
            (error "Emoji changed %s -> %s" telega-help-win--emoji emoji))
          (save-excursion
            (goto-char telega-chatbuf--input-marker)
            (delete-char 1))))
      (telega-chatbuf-attach-sticker sticker)))
  (quit-window 'kill-buffer))

(defun telega-ins--sticker-list (stickers)
  "Insert STICKERS list int current buffer."
  (seq-doseq (sticker stickers)
    (when (> (telega-current-column) (- telega-chat-fill-column 10))
      (telega-ins "\n"))
    (telega-button--insert 'telega-sticker sticker
      'action 'telega-sticker--choosen-action)
    (sit-for 0)))

(defun telega-sticker-choose-favorite-or-recent (for-chat)
  "Choose recent sticker FOR-CHAT."
  (interactive (list telega-chatbuf--chat))
  (cl-assert for-chat)
  (let ((help-window-select t))
    (with-telega-help-win "*Telegram Stickers*"
      (setq telega--chat for-chat)
      (telega-ins "Favorite:\n")
      (telega-ins--sticker-list (telega--getFavoriteStickers))
      (telega-ins "\nRecent:\n")
      (telega-ins--sticker-list (telega--getRecentStickers))
      )))

(defun telega-sticker-choose-emoji (emoji for-chat)
  "Choose sticker by EMOJI FOR-CHAT."
  (let ((help-window-select t))
    (with-telega-help-win "*Telegram Stickers*"
      (setq telega--chat for-chat)
      (setq telega-help-win--emoji emoji)

      ;; TODO: use callbacks for async stickers load
      (let ((istickers (telega--getStickers emoji))
            (sstickers (telega--searchStickers emoji)))
        (telega-ins "Installed:\n")
        (telega-ins--sticker-list istickers)

        (telega-ins "\nPublic:\n")
        (telega-ins--sticker-list sstickers)
        ))))


;;; Animations
(defun telega-animation--ensure-downloaded (animation)
  "Ensure media content for ANIMATION has been downloaded."
  (let ((athumb (plist-get animation :thumbnail)))
    (when (telega-media--need-download-p (plist-get athumb :photo))
      (telega-file--download-monitoring athumb :photo))
    (when (telega-media--need-download-p (plist-get animation :animation))
      (telega-file--download-monitoring animation :animation))
    ))

(defun telega--on-updateSavedAnimations (event)
  "List of saved animations has been updated."
  (setq telega--animations-saved nil)

  (seq-doseq (aid (plist-get event :animation_ids))
    (telega--getFile aid
      (lambda (afile)
        (push afile telega--animations-saved)
        (telega-file--ensure-downloaded
         afile telega--animations-saved)
        ))))

(defun telega--getSavedAnimations ()
  "Return list of saved animations."
  (let ((reply (telega-server--call
                (list :@type "getSavedAnimations"))))
    (mapcar 'identity (plist-get reply :animations))))

(defun telega--addSavedAnimation (input-file)
  "Manually adds a new animation to the list of saved animations."
  (telega-server--send
   (list :@type "addSavedAnimation"
         :animation input-file)))

(defun telega--removeSavedAnimation (input-file)
  "Removes an animation from the list of saved animations."
  (telega-server--send
   (list :@type "removeSavedAnimation"
         :animation input-file)))

(provide 'telega-sticker)

;;; telega-sticker.el ends here
