import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getAssetsForAccount from '@salesforce/apex/AssetViewerController.getAssetsForAccount';

// Color palette for purchaser groups
const GROUP_COLORS = [
    '#0176d3', // Salesforce blue
    '#06a59a', // Teal
    '#e3730c', // Orange
    '#9050e9', // Purple
    '#ea001e', // Red
    '#2e844a', // Green
    '#d83a00', // Burnt orange
    '#3296ed', // Light blue
    '#f59e0b', // Amber
    '#7c3aed', // Violet
];

const RECORD_TYPE_CONFIG = {
    JPA:          { label: 'JPA',          color: '#9050e9', icon: 'standard:account' },
    State_Entity: { label: 'State Entity', color: '#0176d3', icon: 'standard:account' },
    District:     { label: 'District',     color: '#06a59a', icon: 'standard:account' },
    School:       { label: 'School',       color: '#e3730c', icon: 'standard:account' },
};

const STATUS_COLORS = {
    Purchased:  { bg: '#eaf5fe', color: '#0176d3', border: '#b9d6f3' },
    Shipped:    { bg: '#fef3e0', color: '#e3730c', border: '#f9c97b' },
    Installed:  { bg: '#e6f9f0', color: '#2e844a', border: '#91dbb6' },
    Registered: { bg: '#f3ebff', color: '#9050e9', border: '#c8a9f1' },
    Obsolete:   { bg: '#fef1f1', color: '#ea001e', border: '#f5a3a3' },
};

export default class AssetViewer extends NavigationMixin(LightningElement) {
    @api recordId;

    rawResult;
    error;
    isLoading = true;

    searchTerm = '';
    activeProductFilters = new Set();
    activeStatusFilters = new Set();
    expandedGroups = new Set();

    @wire(getAssetsForAccount, { accountId: '$recordId' })
    wiredAssets({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.rawResult = data;
            this.error = undefined;
            // Expand all groups by default
            if (data.purchaserGroups) {
                this.expandedGroups = new Set(data.purchaserGroups.map(g => g.purchaserId));
            }
        } else if (error) {
            this.error = error;
            this.rawResult = undefined;
        }
    }

    // ─── Computed: Header ──────────────────────────────────────────────
    get accountName() {
        return this.rawResult ? this.rawResult.accountName : '';
    }

    get totalAssets() {
        return this.rawResult ? this.rawResult.totalAssets : 0;
    }

    get totalPurchasers() {
        return this.rawResult ? this.rawResult.totalPurchasers : 0;
    }

    get assetPluralSuffix() {
        return this.totalAssets !== 1 ? 's' : '';
    }

    get purchaserPluralSuffix() {
        return this.totalPurchasers !== 1 ? 's' : '';
    }

    get hasData() {
        return this.rawResult && this.rawResult.totalAssets > 0;
    }

    get errorMessage() {
        if (!this.error) return '';
        if (this.error.body && this.error.body.message) return this.error.body.message;
        if (typeof this.error === 'string') return this.error;
        return 'An unexpected error occurred.';
    }

    get showEmptyState() {
        return !this.isLoading && !this.error && this.rawResult && this.rawResult.totalAssets === 0;
    }

    // ─── Computed: Filters ─────────────────────────────────────────────
    get allProducts() {
        if (!this.rawResult || !this.rawResult.purchaserGroups) return [];
        const products = new Set();
        this.rawResult.purchaserGroups.forEach(g => {
            g.assets.forEach(a => {
                if (a.productName) products.add(a.productName);
            });
        });
        return [...products].sort();
    }

    get allStatuses() {
        if (!this.rawResult || !this.rawResult.purchaserGroups) return [];
        const statuses = new Set();
        this.rawResult.purchaserGroups.forEach(g => {
            g.assets.forEach(a => {
                if (a.status) statuses.add(a.status);
            });
        });
        return [...statuses].sort();
    }

    get hasProductFilters() {
        return this.allProducts.length > 1;
    }

    get hasStatusFilters() {
        return this.allStatuses.length > 1;
    }

    get productFilterOptions() {
        return this.allProducts.map(p => ({
            value: p,
            label: p,
            pillClass: this.activeProductFilters.has(p)
                ? 'filter-pill filter-pill-active'
                : 'filter-pill',
        }));
    }

    get statusFilterOptions() {
        return this.allStatuses.map(s => ({
            value: s,
            label: s,
            pillClass: this.activeStatusFilters.has(s)
                ? 'filter-pill filter-pill-active'
                : 'filter-pill',
        }));
    }

    get hasActiveFilters() {
        return this.activeProductFilters.size > 0 ||
               this.activeStatusFilters.size > 0 ||
               this.searchTerm.length > 0;
    }

    // ─── Computed: Summary Bar ─────────────────────────────────────────
    get showSummaryBar() {
        return this.hasData && this.rawResult.purchaserGroups.length > 1;
    }

    get summarySegments() {
        if (!this.rawResult || !this.rawResult.purchaserGroups) return [];
        const total = this.rawResult.totalAssets;
        return this.rawResult.purchaserGroups.map((g, idx) => {
            const color = GROUP_COLORS[idx % GROUP_COLORS.length];
            const pct = total > 0 ? (g.assetCount / total) * 100 : 0;
            return {
                purchaserId: g.purchaserId,
                segmentStyle: `width: ${pct}%; background: ${color};`,
                dotStyle: `background: ${color};`,
                tooltip: `${g.purchaserName}: ${g.assetCount} asset${g.assetCount !== 1 ? 's' : ''} (${Math.round(pct)}%)`,
                label: g.purchaserName,
                count: g.assetCount,
            };
        });
    }

    // ─── Computed: Display Groups ──────────────────────────────────────
    get showGroups() {
        return this.hasData && this.displayGroups.length > 0;
    }

    get showNoResults() {
        return this.hasData && !this.isLoading && !this.error && this.displayGroups.length === 0 && this.hasActiveFilters;
    }

    get displayGroups() {
        if (!this.rawResult || !this.rawResult.purchaserGroups) return [];

        const search = this.searchTerm.toLowerCase().trim();

        return this.rawResult.purchaserGroups
            .map((g, idx) => {
                const color = GROUP_COLORS[idx % GROUP_COLORS.length];
                const rtConfig = RECORD_TYPE_CONFIG[g.purchaserRecordType] || null;

                // Filter assets
                let filtered = g.assets;
                if (this.activeProductFilters.size > 0) {
                    filtered = filtered.filter(a => this.activeProductFilters.has(a.productName));
                }
                if (this.activeStatusFilters.size > 0) {
                    filtered = filtered.filter(a => this.activeStatusFilters.has(a.status));
                }
                if (search) {
                    filtered = filtered.filter(a =>
                        (a.name && a.name.toLowerCase().includes(search)) ||
                        (a.productName && a.productName.toLowerCase().includes(search)) ||
                        (a.status && a.status.toLowerCase().includes(search))
                    );
                }

                if (filtered.length === 0) return null;

                const isExpanded = this.expandedGroups.has(g.purchaserId);

                return {
                    purchaserId: g.purchaserId,
                    purchaserName: g.purchaserName,
                    purchaserUrl: g.purchaserUrl,
                    isSelf: g.isSelf,
                    assetCount: filtered.length,
                    pluralSuffix: filtered.length !== 1 ? 's' : '',
                    isExpanded,
                    expandIcon: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
                    icon: rtConfig ? rtConfig.icon : 'standard:account',
                    iconBgStyle: `background: ${color}1a;`,
                    colorBarStyle: `background: ${color};`,
                    stripeStyle: `background: ${color};`,
                    countBadgeStyle: `background: ${color}14; color: ${color}; border: 1px solid ${color}33;`,
                    recordTypeBadge: rtConfig ? rtConfig.label : '',
                    rtBadgeStyle: rtConfig ? `background: ${rtConfig.color}14; color: ${rtConfig.color}; border: 1px solid ${rtConfig.color}33;` : '',
                    filteredAssets: filtered.map(a => this._enrichAsset(a)),
                };
            })
            .filter(g => g !== null);
    }

    _enrichAsset(asset) {
        const statusConf = STATUS_COLORS[asset.status] || { bg: '#f3f3f3', color: '#706e6b', border: '#d8d8d8' };
        let installDateFormatted = '';
        if (asset.installDate) {
            try {
                const d = new Date(asset.installDate);
                installDateFormatted = d.toLocaleDateString('en-US', {
                    month: 'short',
                    day: 'numeric',
                    year: 'numeric',
                });
            } catch (e) {
                installDateFormatted = asset.installDate;
            }
        }

        return {
            ...asset,
            installDateFormatted,
            hasQuantity: asset.quantity != null && asset.quantity > 0,
            statusClass: `status-pill status-${(asset.status || 'default').toLowerCase().replace(/\s+/g, '-')}`,
            statusStyle: `background: ${statusConf.bg}; color: ${statusConf.color}; border: 1px solid ${statusConf.border};`,
        };
    }

    // ─── Handlers ──────────────────────────────────────────────────────
    handleSearchChange(event) {
        this.searchTerm = event.target.value || '';
    }

    handleFilterToggle(event) {
        event.stopPropagation();
        const value = event.currentTarget.dataset.value;
        const type = event.currentTarget.dataset.type;

        if (type === 'product') {
            const next = new Set(this.activeProductFilters);
            if (next.has(value)) {
                next.delete(value);
            } else {
                next.add(value);
            }
            this.activeProductFilters = next;
        } else if (type === 'status') {
            const next = new Set(this.activeStatusFilters);
            if (next.has(value)) {
                next.delete(value);
            } else {
                next.add(value);
            }
            this.activeStatusFilters = next;
        }
    }

    handleClearFilters() {
        this.activeProductFilters = new Set();
        this.activeStatusFilters = new Set();
        this.searchTerm = '';
    }

    handleToggleGroup(event) {
        // Don't toggle if clicking the navigation link
        if (event.target.closest('.group-link')) return;

        const purchaserId = event.currentTarget.dataset.purchaserId;
        const next = new Set(this.expandedGroups);
        if (next.has(purchaserId)) {
            next.delete(purchaserId);
        } else {
            next.add(purchaserId);
        }
        this.expandedGroups = next;
    }

    handleNavigate(event) {
        event.preventDefault();
        event.stopPropagation();
        const url = event.currentTarget.dataset.url;
        if (url) {
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: { url },
            });
        }
    }
}
