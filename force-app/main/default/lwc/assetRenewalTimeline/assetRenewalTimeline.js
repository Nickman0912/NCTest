/**
 * @description Asset Renewal Timeline LWC.
 *              Displays Assets for the current Account on a custom 18-month
 *              horizontal timeline, with product family / renewal status
 *              filters, hover tooltips, a sleek per-node action menu
 *              (single renewal OR multi-select grouping), and the ability
 *              to create or open linked Renewal Opportunities.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { loadStyle } from 'lightning/platformResourceLoader';
import { refreshApex } from '@salesforce/apex';
import getTimelineData from '@salesforce/apex/AssetTimelineController.getTimelineData';
import createRenewalOpportunity from '@salesforce/apex/AssetTimelineController.createRenewalOpportunity';
import createRenewalOpportunities from '@salesforce/apex/AssetTimelineController.createRenewalOpportunities';

/** Number of months the rolling timeline window covers. */
const WINDOW_MONTHS = 18;

/** Urgency thresholds (in months) driving node colors. */
const URGENCY_CRITICAL = 3; // < 3 months -> red-ish
const URGENCY_WARNING = 6; // < 6 months -> orange
const URGENCY_ATTENTION = 12; // < 12 months -> amber

/** Month label formatter for the axis header. */
const MONTH_LABEL_FORMAT = new Intl.DateTimeFormat('en-US', {
    month: 'short',
    year: 'numeric',
});

export default class AssetRenewalTimeline extends NavigationMixin(LightningElement) {
    /** Record Id of the Account page the component is placed on. */
    @api recordId;

    /**
     * Loads the brand web fonts (Source Sans Pro + Caveat Brush) from Google
     * Fonts. Wrapped in .catch() so a missing CSP Trusted Site entry fails
     * silently — the component still renders with the system fallback stack.
     */
    connectedCallback() {
        loadStyle(
            this,
            'https://fonts.googleapis.com/css2?family=Caveat+Brush&family=Source+Sans+Pro:wght@300;400;600;700&display=swap'
        ).catch(() => {
            // Brand fonts unavailable — system stack fallback is fine.
        });
    }

    disconnectedCallback() {
        this._detachOutsideClickHandler();
    }

    /** Raw data returned from the Apex wire. */
    timelineItems = [];

    /** Filter values. */
    familyFilter = '';
    statusFilter = '';

    /** Tooltip state. */
    tooltipData = null;
    hoveredId = null;

    /** Popout action menu state. */
    menuAsset = null;
    menuLeftPx = 0;
    menuArrowLeftPx = 50;

    /** Batch selection state. */
    selectMode = false;
    selectedAssetIds = [];

    /** Modal state (single renewal). */
    showModal = false;
    modalAsset = null;
    isCreating = false;

    /** UI state. */
    isLoading = true;
    hasError = false;
    errorMessage = '';

    /** Cache of the wire result for refreshApex-style local updates. */
    wiredResult;

    /**
     * Retrieves timeline data via the wire-aware Apex method.
     */
    @wire(getTimelineData, { accountId: '$recordId' })
    wiredTimeline(result) {
        this.wiredResult = result;
        const { data, error } = result;
        this.isLoading = true;

        if (data) {
            this.timelineItems = data;
            this.hasError = false;
            this.errorMessage = '';
        } else if (error) {
            this.hasError = true;
            this.errorMessage = this.getErrorMessage(
                error,
                'Unable to load the Asset Renewal Timeline.'
            );
        }
        this.isLoading = false;
    }

    /* ================= GETTERS ================= */

    /** Whether there is anything to render on the timeline. */
    get showTimeline() {
        return (
            !this.isLoading &&
            !this.hasError &&
            this.filteredNodes &&
            this.filteredNodes.length > 0
        );
    }

    /** Whether to show the empty state. */
    get showEmpty() {
        return (
            !this.isLoading &&
            !this.hasError &&
            (!this.filteredNodes || this.filteredNodes.length === 0)
        );
    }

    /** Filtered Assets after applying family + status filters. */
    get filteredNodes() {
        let nodes = [...this.timelineItems];

        if (this.familyFilter) {
            nodes = nodes.filter(
                (n) => n.productFamily === this.familyFilter
            );
        }
        if (this.statusFilter) {
            nodes = nodes.filter((n) => {
                if (this.statusFilter === 'needsRenewal') {
                    return !n.renewalOpportunityId;
                }
                if (this.statusFilter === 'renewalCreated') {
                    return Boolean(n.renewalOpportunityId);
                }
                return true;
            });
        }
        return nodes;
    }

    /** Options for the Product Family combobox. */
    get familyOptions() {
        const families = new Set(
            this.timelineItems.map((n) => n.productFamily).filter(Boolean)
        );
        return [
            { label: 'All Families', value: '' },
            ...[...families]
                .sort()
                .map((f) => ({ label: f, value: f })),
        ];
    }

    /** Options for the Renewal Status combobox. */
    get statusOptions() {
        return [
            { label: 'All Statuses', value: '' },
            { label: 'Needs Renewal', value: 'needsRenewal' },
            { label: 'Renewal Created', value: 'renewalCreated' },
        ];
    }

    /** Count of Assets still needing a Renewal Opportunity. */
    get needsRenewalCount() {
        return this.timelineItems.filter((n) => !n.renewalOpportunityId).length;
    }

    /** Count of Assets with a linked Renewal Opportunity. */
    get renewedCount() {
        return this.timelineItems.filter((n) => Boolean(n.renewalOpportunityId)).length;
    }

    /** Inline style for the "Today" marker (positioned at the window start). */
    get todayMarkerStyle() {
        return 'left: 0%;';
    }

    /** Inline style for the popout action menu (anchored to the clicked node). */
    get menuStyle() {
        if (!this.menuAsset) return '';
        const left = this.menuLeftPx ?? 0;
        const arrow = this.menuArrowLeftPx ?? 50;
        return `left: ${left.toFixed(1)}px; --arrow-left: ${arrow.toFixed(1)}px;`;
    }

    /** Display name of the asset the menu is anchored to. */
    get menuAssetName() {
        return this.menuAsset ? this.menuAsset.assetName : '';
    }

    /** Comma-separated names of the currently batch-selected assets. */
    get selectedNamesLabel() {
        return this.timelineItems
            .filter((n) => this.selectedAssetIds.includes(n.assetId))
            .map((n) => n.assetName)
            .join(', ');
    }

    /**
     * The account the grouped Opportunity will be created for.
     * If all selected assets share the same purchaser, that purchaser is used;
     * otherwise the current (context) account is used.
     */
    get batchTargetAccountName() {
        const selected = this.timelineItems.filter((n) =>
            this.selectedAssetIds.includes(n.assetId)
        );
        if (selected.length === 0) return '';

        const purchasers = new Set(
            selected.map((n) => n.purchasedById || this.recordId)
        );
        if (purchasers.size === 1) {
            const first = selected[0];
            return first.purchasedByName || 'This account';
        }
        return 'This account';
    }

    /**
     * Month cells for the axis header (18 columns from today).
     */
    get monthCells() {
        const cells = [];
        const now = new Date();
        for (let i = 0; i < WINDOW_MONTHS; i++) {
            const d = new Date(
                now.getFullYear(),
                now.getMonth() + i,
                1
            );
            cells.push({
                key: `m-${i}`,
                label: MONTH_LABEL_FORMAT.format(d),
                axisStyle: `width: ${(100 / WINDOW_MONTHS).toFixed(4)}%;`,
            });
        }
        return cells;
    }

    /**
     * Quarter divider markers (every 3 months).
     */
    get quarterCells() {
        const cells = [];
        for (let i = 0; i < WINDOW_MONTHS; i++) {
            if (i % 3 === 0 && i > 0) {
                cells.push({
                    key: `q-${i}`,
                    markerStyle: `left: ${((i / WINDOW_MONTHS) * 100).toFixed(4)}%;`,
                });
            }
        }
        return cells;
    }

    /**
     * Computes timeline lanes. Nodes are assigned to the first lane that has
     * no overlap with the previous node in that lane, preventing visual overlap
     * for dense clusters. Each lane becomes a flex row.
     */
    get lanes() {
        const nodes = this.filteredNodes || [];
        if (nodes.length === 0) return [];

        // Sort by expiration date ascending before laying out
        const sorted = [...nodes].sort(
            (a, b) => new Date(a.expirationDate) - new Date(b.expirationDate)
        );

        const laneArrays = [];
        const laneLastEnd = [];

        const NODE_MIN_WIDTH_PCT = 14; // approx node width as a % to avoid collisions

        sorted.forEach((n, idx) => {
            const pct = this.expirationToPercent(n.expirationDate);

            let laneIdx = 0;
            let placed = false;
            while (!placed) {
                const lastEnd = laneLastEnd[laneIdx] ?? -Infinity;
                if (lastEnd === -Infinity || pct - lastEnd >= NODE_MIN_WIDTH_PCT) {
                    placed = true;
                } else {
                    laneIdx += 1;
                }
            }

            if (!laneArrays[laneIdx]) {
                laneArrays[laneIdx] = [];
                laneLastEnd[laneIdx] = -Infinity;
            }

            laneArrays[laneIdx].push(this.buildNode(n, idx));
            const right = pct + NODE_MIN_WIDTH_PCT / 2;
            laneLastEnd[laneIdx] = Math.max(laneLastEnd[laneIdx] ?? -Infinity, right);
        });

        return laneArrays.map((assets, laneIdx) => ({
            id: `lane-${laneIdx}`,
            assets,
        }));
    }

    /**
     * Builds a single node wrapper with the computed inline style (left %),
     * a pre-computed CSS class string, and selection/batch state.
     */
    buildNode(item, index) {
        const pct = this.expirationToPercent(item.expirationDate);
        const isLinked = Boolean(item.renewalOpportunityId);

        // Ensure a positive, bounded left offset
        const left = Math.max(2, Math.min(96, pct));

        const styleClass = isLinked
            ? 'tl-node_ok'
            : this.urgencyClass(item.expirationDate);

        const isSelected = this.selectedAssetIds.includes(item.assetId);

        // Staggered fade-in animation delay (capped so dense lists don't stall UI)
        const delay = Math.min(index * 45, 1200);

        return {
            ...item,
            isLinked,
            isSelected,
            styleClass,
            tlClass: `tl-node ${styleClass}${isLinked ? ' tl-node_linked' : ''}${
                isSelected ? ' tl-node_selected' : ''
            }`,
            positionStyle: `left: ${left.toFixed(2)}%; animation-delay: ${delay}ms;`,
            shortDate: this.formatShortDate(item.expirationDate),
        };
    }

    /** Formats a date as a compact "Mon D" label for node cards. */
    formatShortDate(dateValue) {
        if (!dateValue) return '';
        return this.formatDate(dateValue, {
            month: 'short',
            day: 'numeric',
        });
    }

    /**
     * Maps an expiration date to a percentage position on the 18-month axis.
     */
    expirationToPercent(expirationDate) {
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const exp = new Date(expirationDate);
        exp.setHours(0, 0, 0, 0);

        const totalMs = this.windowEndMs - today.getTime();
        const elapsedMs = exp.getTime() - today.getTime();

        if (totalMs <= 0) return 0;
        const raw = (elapsedMs / totalMs) * 100;
        return Math.max(0, Math.min(100, raw));
    }

    /** Cache for the window end (today + 18 months) in ms. */
    get windowEndMs() {
        const now = new Date();
        const end = new Date(
            now.getFullYear(),
            now.getMonth() + WINDOW_MONTHS,
            now.getDate(),
            23, 59, 59, 999
        );
        return end.getTime();
    }

    /**
     * Determines the urgency CSS class based on how close the expiration is.
     */
    urgencyClass(expirationDate) {
        const exp = new Date(expirationDate);
        const monthsDiff = this.monthsBetween(new Date(), exp);
        if (monthsDiff < URGENCY_CRITICAL) return 'tl-node_critical';
        if (monthsDiff < URGENCY_WARNING) return 'tl-node_warning';
        if (monthsDiff < URGENCY_ATTENTION) return 'tl-node_attention';
        return 'tl-node_future';
    }

    /**
     * Approximate whole + fractional months between two dates.
     */
    monthsBetween(start, end) {
        const ms = end.getTime() - start.getTime();
        return ms / (1000 * 60 * 60 * 24 * 30.44);
    }

    /* ================= FILTER HANDLERS ================= */

    handleFamilyChange(event) {
        this.familyFilter = event.detail.value;
    }

    handleStatusChange(event) {
        this.statusFilter = event.detail.value;
    }

    /* ================= HOVER / TOOLTIP ================= */

    handleMouseEnter(event) {
        const id = event.currentTarget.dataset.assetId;
        this.hoveredId = id;
        const node = this.findNode(id);
        if (node) {
            this.tooltipData = this.buildTooltip(node);
        }
    }

    handleMouseLeave() {
        this.hoveredId = null;
        this.tooltipData = null;
    }

    /** Keyboard accessibility: same as click on Enter/Space. */
    handleNodeKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleNodeClick(event);
        }
    }

    /**
     * Builds the tooltip object for a node.
     */
    buildTooltip(node) {
        const isLinked = Boolean(node.renewalOpportunityId);
        return {
            assetName: node.assetName,
            expirationLabel: this.formatDate(node.expirationDate),
            productFamily: node.productFamily || '—',
            status: node.status || '—',
            purchasedBy: node.isSelfPurchased
                ? 'This account'
                : node.purchasedByName || '—',
            badgeClass: isLinked ? 'tl-tooltip-badge_ok' : this.urgencyBadgeClass(node.expirationDate),
            badgeText: isLinked ? 'Renewal Created' : 'Needs Renewal',
        };
    }

    /** Maps urgency to tooltip badge styles. */
    urgencyBadgeClass(expirationDate) {
        const monthsDiff = this.monthsBetween(new Date(), new Date(expirationDate));
        if (monthsDiff < URGENCY_CRITICAL) return 'tl-tooltip-badge_critical';
        if (monthsDiff < URGENCY_WARNING) return 'tl-tooltip-badge_warning';
        return 'tl-tooltip-badge_attention';
    }

    /** Tooltip left position: near the node (clamped). */
    get tooltipStyle() {
        if (!this.tooltipData) return '';
        return `left: 55%; transform: translateX(-50%); top: -10px;`;
    }

    /* ================= CLICK / ACTION MENU ================= */

    handleNodeClick(event) {
        const id = event.currentTarget.dataset.assetId;
        const node = this.findNode(id);
        if (!node) return;

        // Linked assets always open the existing Opportunity
        if (node.renewalOpportunityId) {
            this.navigateToOpportunity(node.renewalOpportunityId);
            return;
        }

        // In batch-select mode, clicking toggles selection instead
        if (this.selectMode) {
            this.toggleSelect(id);
            return;
        }

        // Default: open the sleek action menu anchored to this node
        this.menuAsset = node;
        this._positionMenu(node);
        this._attachOutsideClickHandler();
    }

    /**
     * Positions the popout action menu in exact pixels so it is centered on
     * the clicked node and clamped to the timeline container — it can never
     * overflow the left or right edge. Also computes the arrow position so it
     * still points at the node even when the menu is clamped.
     */
    _positionMenu(node) {
        const timelineEl = this.template.querySelector('.timeline');
        const nodeEl = this.template.querySelector(
            `[data-asset-id="${node.assetId}"]`
        );
        if (!timelineEl || !nodeEl) return;

        const MENU_WIDTH = 220;
        const EDGE_PAD = 8;

        const timelineRect = timelineEl.getBoundingClientRect();
        const nodeRect = nodeEl.getBoundingClientRect();
        const containerWidth = timelineRect.width;

        // Node center relative to the timeline container
        const nodeCenter =
            nodeRect.left - timelineRect.left + nodeRect.width / 2;

        // Center the menu on the node, then clamp so it never overflows either side
        let menuLeft = nodeCenter - MENU_WIDTH / 2;
        menuLeft = Math.max(
            EDGE_PAD,
            Math.min(containerWidth - MENU_WIDTH - EDGE_PAD, menuLeft)
        );

        // Arrow points at the node center (clamped to stay inside the menu)
        let arrowLeft = nodeCenter - menuLeft;
        arrowLeft = Math.max(12, Math.min(MENU_WIDTH - 12, arrowLeft));

        this.menuLeftPx = menuLeft;
        this.menuArrowLeftPx = arrowLeft;
    }

    /** Closes the popout action menu. */
    closeMenu() {
        this.menuAsset = null;
        this._detachOutsideClickHandler();
    }

    /**
     * Attaches a document-level click listener (deferred so the opening click
     * doesn't immediately close the menu). Clicks inside the menu or on a
     * timeline node are ignored so switching nodes cleanly re-anchors the menu.
     */
    _attachOutsideClickHandler() {
        this._detachOutsideClickHandler();
        this._boundDocumentClick = this._handleDocumentClick.bind(this);
        setTimeout(() => {
            if (this.menuAsset) {
                document.addEventListener('click', this._boundDocumentClick);
            }
        }, 0);
    }

    /** Document click handler — closes the menu when clicking elsewhere. */
    _handleDocumentClick(event) {
        let path = [];
        try {
            if (typeof event.composedPath === 'function') {
                path = event.composedPath();
            } else if (event.path) {
                path = event.path;
            }
        } catch (e) {
            path = [];
        }
        const inMenu = path.some(
            (el) => el && el.classList && el.classList.contains('tl-menu')
        );
        const inNode = path.some(
            (el) => el && el.dataset && el.dataset.assetId
        );
        if (!inMenu && !inNode) {
            this.closeMenu();
        }
    }

    /** Removes the document click listener. */
    _detachOutsideClickHandler() {
        if (this._boundDocumentClick) {
            document.removeEventListener('click', this._boundDocumentClick);
            this._boundDocumentClick = null;
        }
    }

    /** Menu action: proceed with a single renewal for the anchored asset. */
    handleMenuRenewSingle() {
        if (!this.menuAsset) return;
        this.modalAsset = this.menuAsset;
        this.closeMenu();
        this.showModal = true;
    }

    /** Whether the modal asset was purchased by another account. */
    get modalIsExternalPurchase() {
        return this.modalAsset ? !this.modalAsset.isSelfPurchased : false;
    }

    /** Name of the account that purchased the modal asset. */
    get modalPurchaserName() {
        return this.modalAsset && this.modalAsset.purchasedByName
            ? this.modalAsset.purchasedByName
            : '';
    }

    /** Label for the modal confirm button. */
    get modalConfirmLabel() {
        return this.modalIsExternalPurchase ? 'Create Opportunity' : 'Create';
    }

    /** Menu action: enter multi-select mode with this asset pre-selected. */
    handleMenuSelectMultiple() {
        if (!this.menuAsset) return;
        this.selectMode = true;
        this.toggleSelect(this.menuAsset.assetId);
    }

    /** Toggles an asset in/out of the batch selection set. */
    toggleSelect(assetId) {
        const idx = this.selectedAssetIds.indexOf(assetId);
        if (idx >= 0) {
            this.selectedAssetIds = this.selectedAssetIds.filter((i) => i !== assetId);
        } else {
            this.selectedAssetIds = [...this.selectedAssetIds, assetId];
        }
        // Always close the menu after a selection action
        this.closeMenu();
    }

    /** Exits batch-select mode and clears the selection. */
    cancelSelection() {
        this.selectMode = false;
        this.selectedAssetIds = [];
        this.closeMenu();
    }

    /* ================= MODAL (SINGLE RENEWAL) ================= */

    /** Closes the confirmation modal. */
    closeModal() {
        this.showModal = false;
        this.modalAsset = null;
    }

    /** Confirmation handler — calls the imperative single Apex method. */
    async confirmCreate() {
        if (!this.modalAsset || this.isCreating) return;

        this.isCreating = true;
        try {
            await createRenewalOpportunity({
                accountId: this.recordId,
                assetId: this.modalAsset.assetId,
            });

            // Re-sync with the server so the linked state is authoritative
            await refreshApex(this.wiredResult);

            this.showToast(
                'Success',
                `Renewal Opportunity created for ${this.modalAsset.assetName}.`,
                'success'
            );
            this.closeModal();
        } catch (err) {
            this.showToast(
                'Error',
                this.getErrorMessage(err, 'Unable to create the Renewal Opportunity.'),
                'error'
            );
        } finally {
            this.isCreating = false;
        }
    }

    /** Opens the Opportunity record using NavigationMixin. */
    navigateToOpportunity(oppId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: oppId,
                objectApiName: 'Opportunity',
                actionName: 'view',
            },
        });
    }

    /* ================= BATCH (MULTI-SELECT) RENEWAL ================= */

    /** Confirmation handler for the floating batch bar — groups all selected. */
    async confirmBulkCreate() {
        if (this.isCreating || this.selectedAssetIds.length === 0) return;

        this.isCreating = true;
        try {
            await createRenewalOpportunities({
                accountId: this.recordId,
                assetIds: this.selectedAssetIds,
            });

            // Re-sync with the server so the linked state is authoritative
            await refreshApex(this.wiredResult);

            const count = this.selectedAssetIds.length;
            this.showToast(
                'Success',
                `Renewal Opportunity created for ${count} asset${count > 1 ? 's' : ''}.`,
                'success'
            );
            this.cancelSelection();
        } catch (err) {
            this.showToast(
                'Error',
                this.getErrorMessage(err, 'Unable to create the Renewal Opportunity.'),
                'error'
            );
        } finally {
            this.isCreating = false;
        }
    }

    /* ================= HELPERS ================= */

    /** Finds a timeline item by asset Id from the ORIGINAL dataset. */
    findNode(assetId) {
        return this.timelineItems.find((n) => n.assetId === assetId);
    }

    /** Formats a date string or Date object to a readable label. */
    formatDate(dateValue, options = {}) {
        if (!dateValue) return '—';
        const d = new Date(dateValue);
        return d.toLocaleDateString('en-US', {
            year: 'numeric',
            month: 'short',
            day: 'numeric',
            ...options,
        });
    }

    /**
     * Extracts a user-friendly message from an Apex wire/imperative error,
     * falling back to a supplied default when none is available.
     */
    getErrorMessage(err, fallback) {
        return err && err.body && err.body.message ? err.body.message : fallback;
    }

    /** Fires a ShowToastEvent. */
    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant,
            })
        );
    }

    /** Modal display helpers. */
    get modalAssetName() {
        return this.modalAsset ? this.modalAsset.assetName : '';
    }

    get modalExpirationLabel() {
        return this.modalAsset ? this.formatDate(this.modalAsset.expirationDate) : '';
    }

    get modalProductFamily() {
        return this.modalAsset ? this.modalAsset.productFamily || '—' : '';
    }
}