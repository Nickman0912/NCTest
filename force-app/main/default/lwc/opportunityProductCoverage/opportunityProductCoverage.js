import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { loadStyle } from 'lightning/platformResourceLoader';
import getProductCoverage from '@salesforce/apex/OpportunityProductCoverageController.getProductCoverage';

// Raptor Technologies brand palette for hierarchy levels
const LEVEL_COLORS = [
    { bg: '#4e83d1', light: '#eaf1fa', border: '#b8cfe9', text: '#2a538f' },   // Raptor Blue
    { bg: '#33a78f', light: '#e6f5f2', border: '#9dd9cb', text: '#1f6b5c' },   // Raptor Teal
    { bg: '#faa21b', light: '#fef3e0', border: '#fad79a', text: '#8a5a06' },   // Raptor Orange
    { bg: '#3b5c82', light: '#e8eef5', border: '#aec0d4', text: '#283f58' },   // Raptor Dark Blue
    { bg: '#c14f02', light: '#fbe9e0', border: '#e8a989', text: '#7c3201' },   // Raptor Dark Orange
    { bg: '#707071', light: '#eeeeee', border: '#c0c0c1', text: '#474749' },   // Raptor Gray
    { bg: '#233c5b', light: '#e4eaf2', border: '#9fb3cc', text: '#16283d' },   // Raptor Navy
];

const RECORD_TYPE_CONFIG = {
    JPA:          { label: 'JPA',          color: '#3b5c82', icon: 'standard:account' },
    State_Entity: { label: 'State Entity', color: '#33a78f', icon: 'standard:account' },
    District:     { label: 'District',     color: '#4e83d1', icon: 'standard:account' },
    School:       { label: 'School',       color: '#faa21b', icon: 'standard:account' },
};

const STATUS_COLORS = {
    Purchased:  { bg: '#eaf1fa', color: '#4e83d1', border: '#b8cfe9' },
    Shipped:    { bg: '#fef3e0', color: '#c14f02', border: '#fad79a' },
    Installed:  { bg: '#e6f5f2', color: '#1f6b5c', border: '#9dd9cb' },
    Registered: { bg: '#e8eef5', color: '#3b5c82', border: '#aec0d4' },
    Obsolete:   { bg: '#fbe9e0', color: '#c14f02', border: '#e8a989' },
};

export default class OpportunityProductCoverage extends NavigationMixin(LightningElement) {
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

    rawResult;
    error;
    isLoading = true;

    searchTerm = '';
    activeProductFilters = new Set();
    ownersOnly = false;
    expandedLevels = new Set();

    @wire(getProductCoverage, { opportunityId: '$recordId' })
    wiredCoverage({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.rawResult = data;
            this.error = undefined;
            // Expand all levels by default
            if (data.hierarchyAccounts) {
                const depths = new Set(data.hierarchyAccounts.map(a => a.depth));
                this.expandedLevels = new Set(depths);
            }
        } else if (error) {
            this.error = error;
            this.rawResult = undefined;
        }
    }

    // ─── Computed: Header ──────────────────────────────────────────────
    get opportunityName() {
        return this.rawResult ? this.rawResult.opportunityName : '';
    }

    get accountName() {
        return this.rawResult ? this.rawResult.accountName : '';
    }

    get totalProducts() {
        return this.rawResult ? this.rawResult.products.length : 0;
    }

    get totalAccounts() {
        return this.rawResult ? this.rawResult.totalAccounts : 0;
    }

    get totalAccountsWithOwnership() {
        return this.rawResult ? this.rawResult.totalAccountsWithOwnership : 0;
    }

    get productPluralSuffix() {
        return this.totalProducts !== 1 ? 's' : '';
    }

    get accountPluralSuffix() {
        return this.totalAccounts !== 1 ? 's' : '';
    }

    get ownerPluralSuffix() {
        return this.totalAccountsWithOwnership !== 1 ? 's' : '';
    }

    get hasData() {
        return this.rawResult && this.rawResult.products.length > 0;
    }

    get hasOwners() {
        return this.totalAccountsWithOwnership > 0;
    }

    get errorMessage() {
        if (!this.error) return '';
        if (this.error.body && this.error.body.message) return this.error.body.message;
        if (typeof this.error === 'string') return this.error;
        return 'An unexpected error occurred.';
    }

    get showEmptyState() {
        return !this.isLoading && !this.error && this.rawResult && this.rawResult.products.length === 0;
    }

    // ─── Computed: Filters ─────────────────────────────────────────────
    get allProducts() {
        if (!this.rawResult || !this.rawResult.products) return [];
        return this.rawResult.products.map(p => p.productName).sort();
    }

    get hasProductFilters() {
        return this.allProducts.length > 1;
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

    get ownersOnlyPillClass() {
        return this.ownersOnly ? 'filter-pill filter-pill-active' : 'filter-pill';
    }

    get hasActiveFilters() {
        return this.activeProductFilters.size > 0 ||
               this.ownersOnly ||
               this.searchTerm.length > 0;
    }

    // ─── Computed: Product Coverage Summary ────────────────────────────
    get productCoverageItems() {
        if (!this.rawResult || !this.rawResult.products) return [];
        const total = this.totalAccounts;
        return this.rawResult.products.map(p => {
            const pct = total > 0 ? (p.ownerCount / total) * 100 : 0;
            const color = p.ownerCount > 0 ? '#4e83d1' : '#e4e4e4';
            return {
                productId: p.productId,
                productName: p.productName,
                ownerCount: p.ownerCount,
                ownerPluralSuffix: p.ownerCount !== 1 ? 's' : '',
                assetCount: p.assetCount,
                assetPluralSuffix: p.assetCount !== 1 ? 's' : '',
                percentText: `${Math.round(pct)}%`,
                barStyle: `width: ${pct}%; background: ${color};`,
                ownerBadgeStyle: p.ownerCount > 0
                    ? `background: #eaf1fa; color: #4e83d1; border: 1px solid #b8cfe9;`
                    : `background: #f3f3f3; color: #707071; border: 1px solid #d8d8d8;`,
            };
        });
    }

    // ─── Computed: Hierarchy Levels ────────────────────────────────────
    get showLevels() {
        return this.hasData && this.levelGroups.length > 0;
    }

    get showNoResults() {
        return this.hasData && !this.isLoading && !this.error && this.levelGroups.length === 0 && this.hasActiveFilters;
    }

    get levelGroups() {
        if (!this.rawResult || !this.rawResult.hierarchyAccounts) return [];

        const search = this.searchTerm.toLowerCase().trim();
        const filteredAccounts = this.rawResult.hierarchyAccounts.filter(acc => {
            // Owners only filter
            if (this.ownersOnly && acc.ownedAssets.length === 0) return false;
            // Product filter
            if (this.activeProductFilters.size > 0) {
                const ownedProducts = acc.ownedAssets.map(a => a.productName);
                const hasMatch = ownedProducts.some(p => this.activeProductFilters.has(p));
                if (!hasMatch) return false;
            }
            // Search
            if (search) {
                const nameMatch = acc.name && acc.name.toLowerCase().includes(search);
                const parentMatch = acc.parentName && acc.parentName.toLowerCase().includes(search);
                if (!nameMatch && !parentMatch) return false;
            }
            return true;
        });

        // Group by depth
        const depthMap = new Map();
        filteredAccounts.forEach(acc => {
            if (!depthMap.has(acc.depth)) {
                depthMap.set(acc.depth, []);
            }
            depthMap.get(acc.depth).push(acc);
        });

        const depths = [...depthMap.keys()].sort((a, b) => a - b);
        return depths.map((depth, idx) => {
            const accounts = depthMap.get(depth);
            const color = LEVEL_COLORS[idx % LEVEL_COLORS.length];
            const isExpanded = this.expandedLevels.has(depth);

            return {
                depth,
                label: this._levelLabel(depth),
                badgeStyle: `background: ${color.light}; color: ${color.text}; border: 1px solid ${color.border};`,
                accounts: accounts.map(acc => this._buildAccountCard(acc, color)),
                pluralSuffix: accounts.length !== 1 ? 's' : '',
                isExpanded,
                expandIcon: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
                toggleLabel: isExpanded ? 'Collapse' : 'Expand',
            };
        });
    }

    _levelLabel(depth) {
        if (depth === 0) return 'This Account';
        if (depth === 1) return 'Level 1 — Direct Children';
        if (depth === 2) return 'Level 2 — Grandchildren';
        return `Level ${depth}`;
    }

    _buildAccountCard(acc, levelColor) {
        const rtConfig = RECORD_TYPE_CONFIG[acc.recordType] || null;
        const color = rtConfig ? rtConfig.color : levelColor.bg;

        return {
            id: acc.id,
            name: acc.name,
            accountUrl: acc.accountUrl,
            isSelf: acc.isSelf,
            parentName: acc.parentName,
            recordTypeLabel: rtConfig ? rtConfig.label : acc.recordType,
            icon: rtConfig ? rtConfig.icon : 'standard:account',
            iconBgStyle: `background: ${color}1a;`,
            stripeStyle: `background: ${color};`,
            rtBadgeStyle: rtConfig
                ? `background: ${rtConfig.color}14; color: ${rtConfig.color}; border: 1px solid ${rtConfig.color}33;`
                : `background: ${levelColor.light}; color: ${levelColor.text}; border: 1px solid ${levelColor.border};`,
            hasOwnedAssets: acc.ownedAssets.length > 0,
            ownedAssets: acc.ownedAssets.map(a => this._enrichAsset(a)),
        };
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
        const next = new Set(this.activeProductFilters);
        if (next.has(value)) {
            next.delete(value);
        } else {
            next.add(value);
        }
        this.activeProductFilters = next;
    }

    handleOwnersOnlyToggle(event) {
        event.stopPropagation();
        this.ownersOnly = !this.ownersOnly;
    }

    handleClearFilters() {
        this.activeProductFilters = new Set();
        this.ownersOnly = false;
        this.searchTerm = '';
    }

    handleToggleLevel(event) {
        const depth = parseInt(event.currentTarget.dataset.depth, 10);
        const next = new Set(this.expandedLevels);
        if (next.has(depth)) {
            next.delete(depth);
        } else {
            next.add(depth);
        }
        this.expandedLevels = next;
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