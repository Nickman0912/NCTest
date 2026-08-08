import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { loadStyle } from 'lightning/platformResourceLoader';
import getHierarchyData from '@salesforce/apex/RelationshipHierarchyController.getHierarchyData';
import getChildSchools from '@salesforce/apex/RelationshipHierarchyController.getChildSchools';

const ICON_MAP = {
    JPA: 'standard:partner_fund_claim',
    State_Entity: 'standard:government',
    District: 'standard:account',
    School: 'standard:education'
};

const LABEL_MAP = {
    JPA: 'JPA',
    State_Entity: 'State Entity',
    District: 'District',
    School: 'School'
};

// Raptor Technologies brand palette mapped to entity record types.
const COLOR_MAP = {
    JPA: { bg: '#3b5c82', light: '#e8eef5', border: '#3b5c82', text: '#283f58' },       // Raptor Dark Blue
    State_Entity: { bg: '#33a78f', light: '#e6f5f2', border: '#33a78f', text: '#1f6b5c' }, // Raptor Teal
    District: { bg: '#4e83d1', light: '#eaf1fa', border: '#4e83d1', text: '#2a538f' },   // Raptor Blue
    School: { bg: '#faa21b', light: '#fef3e0', border: '#faa21b', text: '#8a5a06' }      // Raptor Orange
};

// Distinct brand-tinted palette for district-grouped schools
const DISTRICT_COLORS = [
    { bg: '#4e83d1', light: '#eaf1fa', border: '#b8cfe9', text: '#2a538f', accent: '#4e83d1' },
    { bg: '#faa21b', light: '#fef3e0', border: '#fad79a', text: '#8a5a06', accent: '#faa21b' },
    { bg: '#33a78f', light: '#e6f5f2', border: '#9dd9cb', text: '#1f6b5c', accent: '#33a78f' },
    { bg: '#3b5c82', light: '#e8eef5', border: '#aec0d4', text: '#283f58', accent: '#3b5c82' },
    { bg: '#c14f02', light: '#fbe9e0', border: '#e8a989', text: '#7c3201', accent: '#c14f02' },
    { bg: '#707071', light: '#eeeeee', border: '#c0c0c1', text: '#474749', accent: '#707071' },
    { bg: '#d2e8ee', light: '#f2fafc', border: '#a8d6df', text: '#23606b', accent: '#d2e8ee' },
    { bg: '#233c5b', light: '#e4eaf2', border: '#9fb3cc', text: '#16283d', accent: '#233c5b' }
];

export default class RelationshipHierarchyViewer extends NavigationMixin(LightningElement) {
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

    @track parentEntities = [];
    @track childEntities = [];
    @track activeFilters = new Set();
    @track schoolsByDistrict = {};    // { districtId: { name, colorIndex, schools[], expanded } }
    @track expandedDistricts = new Set();

    contextRecordType = '';
    contextAccountName = '';
    isLoading = true;
    isLoadingChildren = false;
    error = null;
    showSchools = true;
    _schoolsLoaded = false;

    // ─── Context getters ─────────────────────────────────────────────────
    get contextLabel() {
        return LABEL_MAP[this.contextRecordType] || this.contextRecordType;
    }

    get contextIcon() {
        return ICON_MAP[this.contextRecordType] || 'standard:account';
    }

    get totalRelationships() {
        let count = (this.parentEntities ? this.parentEntities.length : 0) +
                    (this.childEntities ? this.childEntities.length : 0);
        if (this.childEntities) {
            this.childEntities.forEach((ce) => {
                if (ce._children) count += ce._children.length;
            });
        }
        return count;
    }

    get pluralSuffix() {
        return this.totalRelationships === 1 ? '' : 's';
    }

    get hasData() {
        const hasParents = this.parentEntities && this.parentEntities.length > 0;
        const hasChildren = this.childEntities && this.childEntities.length > 0;
        return !this.isLoading && !this.error && (hasParents || hasChildren);
    }

    get showEmptyState() {
        return !this.isLoading && !this.error && !this.hasData;
    }

    get showMap() {
        return this.hasData;
    }

    get hasActiveFilters() {
        return this.activeFilters.size > 0;
    }

    get errorMessage() {
        if (!this.error) return '';
        if (typeof this.error === 'string') return this.error;
        if (this.error.body && this.error.body.message) return this.error.body.message;
        if (this.error.message) return this.error.message;
        return 'An unexpected error occurred.';
    }

    get showSchoolsToggle() {
        return (
            this.contextRecordType === 'JPA' ||
            this.contextRecordType === 'State_Entity' ||
            this.contextRecordType === 'District'
        );
    }

    // ─── Filter options ──────────────────────────────────────────────────
    get filterOptions() {
        const types = this._extractAllRelationshipTypes();
        return types.map((t) => ({
            value: t,
            label: t,
            pillClass: this.activeFilters.has(t) ? 'filter-pill filter-pill-active' : 'filter-pill'
        }));
    }

    // ─── PARENT TIER ─────────────────────────────────────────────────────
    get hasParentTier() {
        return this._filteredParents().length > 0;
    }

    get parentTierLabel() {
        if (this.contextRecordType === 'School') return 'Parent District';
        return 'Parent Entities';
    }

    get parentNodes() {
        return this._filteredParents().map((n) => this._buildCardNode(n));
    }

    // ─── ENTITY TIER (School view) ───────────────────────────────────────
    get hasEntityTierForSchool() {
        if (this.contextRecordType !== 'School') return false;
        const districtNode = this.parentEntities[0];
        return districtNode && districtNode._children && districtNode._children.length > 0;
    }

    get entityNodesForSchool() {
        if (!this.parentEntities[0]) return [];
        const entities = this._filterByType(this.parentEntities[0]._children || []);
        return entities.map((n) => this._buildCardNode(n));
    }

    // ─── District node for School view ───────────────────────────────────
    get hasDistrictForSchool() {
        return this.contextRecordType === 'School' && this.parentEntities.length > 0;
    }

    get districtNodeForSchool() {
        if (!this.parentEntities[0]) return [];
        return [this._buildCardNode({ ...this.parentEntities[0], _children: [] })];
    }

    // ─── FOCAL TIER ──────────────────────────────────────────────────────
    get focalTierLabel() {
        return LABEL_MAP[this.contextRecordType] || 'Current Account';
    }

    get focalNode() {
        const rt = this.contextRecordType;
        const colors = COLOR_MAP[rt] || COLOR_MAP.District;
        const node = {
            id: this.recordId,
            name: this.contextAccountName,
            icon: ICON_MAP[rt] || 'standard:account',
            typeLabel: LABEL_MAP[rt] || rt,
            cardClass: 'node-card node-card-focal',
            iconStyle: `background-color: ${colors.bg};`,
            badgeStyle: `background-color: ${colors.light}; color: ${colors.text}; border: 1px solid ${colors.border};`,
            hasSchoolExpander: false,
            isExpanded: false,
            expandIcon: 'utility:chevronright',
            expandLabel: 'Show Schools',
            schoolCount: 0
        };

        // District focal gets a school expander when "Show Schools" toggle is on
        if (rt === 'District' && this.showSchools) {
            const dColor = DISTRICT_COLORS[0];
            node.hasSchoolExpander = true;
            node.isExpanded = this.expandedDistricts.has(this.recordId);
            node.expandIcon = node.isExpanded ? 'utility:chevrondown' : 'utility:chevronright';
            node.expandLabel = node.isExpanded ? 'Hide Schools' : 'Show Schools';
            node.schoolCount = this._getSchoolCountForDistrict(this.recordId);
            node.stripeStyle = `border-left: 4px solid ${dColor.accent};`;
        }

        return node;
    }

    get showFocalAtTop() {
        return this.contextRecordType !== 'School';
    }

    get showFocalAtBottom() {
        return this.contextRecordType === 'School';
    }

    // ─── CHILD TIER ──────────────────────────────────────────────────────
    get hasChildTier() {
        if (this.contextRecordType === 'School') return false;
        return this._filteredChildren().length > 0;
    }

    get childTierLabel() {
        const children = this._filteredChildren();
        if (children.length === 0) return 'Related';
        const types = new Set(children.map((c) => c.recordType));
        if (types.has('District') && types.size === 1) return 'Districts';
        if (types.has('JPA') && types.size === 1) return 'Child JPAs';
        if (types.has('District') && types.has('JPA')) return 'Districts & JPAs';
        return 'Related Accounts';
    }

    get childNodes() {
        const districtIds = this._getAllDistrictIds();
        let colorIdx = 0;
        const districtColorMap = {};
        districtIds.forEach((id) => {
            districtColorMap[id] = colorIdx % DISTRICT_COLORS.length;
            colorIdx++;
        });

        return this._filteredChildren().map((n) => {
            const card = this._buildCardNode(n);
            // Add color stripe for districts
            if (n.recordType === 'District' && districtColorMap[n.id] !== undefined) {
                const dColor = DISTRICT_COLORS[districtColorMap[n.id]];
                card.districtColorIdx = districtColorMap[n.id];
                card.stripeStyle = `border-left: 4px solid ${dColor.accent};`;
                card.hasSchoolExpander = this.showSchools;
                card.isExpanded = this.expandedDistricts.has(n.id);
                card.expandIcon = card.isExpanded ? 'utility:chevrondown' : 'utility:chevronright';
                card.expandLabel = card.isExpanded ? 'Hide Schools' : 'Show Schools';
                card.schoolCount = this._getSchoolCountForDistrict(n.id);
                card.isLoadingSchools = this.isLoadingChildren && !this.schoolsByDistrict[n.id];
            }
            if (n._children) {
                const districtChildren = n._children.filter((c) => c.recordType === 'District');
                card.childCount = districtChildren.length;
                card.childPluralSuffix = districtChildren.length === 1 ? '' : 's';
            }
            return card;
        });
    }

    // ─── GRANDCHILD TIER ─────────────────────────────────────────────────
    get hasGrandchildTier() {
        if (this.contextRecordType === 'School') return false;
        return this._getGrandchildren().length > 0;
    }

    get grandchildTierLabel() {
        return 'Districts';
    }

    get grandchildNodes() {
        const districtIds = this._getAllDistrictIds();
        let colorIdx = 0;
        const districtColorMap = {};
        districtIds.forEach((id) => {
            districtColorMap[id] = colorIdx % DISTRICT_COLORS.length;
            colorIdx++;
        });

        return this._getGrandchildren().map((n) => {
            const card = this._buildCardNode(n);
            if (n.recordType === 'District' && districtColorMap[n.id] !== undefined) {
                const dColor = DISTRICT_COLORS[districtColorMap[n.id]];
                card.districtColorIdx = districtColorMap[n.id];
                card.stripeStyle = `border-left: 4px solid ${dColor.accent};`;
                card.hasSchoolExpander = this.showSchools;
                card.isExpanded = this.expandedDistricts.has(n.id);
                card.expandIcon = card.isExpanded ? 'utility:chevrondown' : 'utility:chevronright';
                card.expandLabel = card.isExpanded ? 'Hide Schools' : 'Show Schools';
                card.schoolCount = this._getSchoolCountForDistrict(n.id);
                card.isLoadingSchools = this.isLoadingChildren && !this.schoolsByDistrict[n.id];
            }
            return card;
        });
    }

    // ─── School tier (grouped by district) ───────────────────────────────
    get hasSchoolTier() {
        if (!this.showSchools) return false;
        if (this.contextRecordType === 'District') {
            return this.expandedDistricts.has(this.recordId);
        }
        return this.expandedDistricts.size > 0;
    }

    get districtSchoolGroups() {
        const groups = [];
        const districtIds = this._getAllDistrictIds();
        let colorIdx = 0;
        const districtColorMap = {};
        districtIds.forEach((id) => {
            districtColorMap[id] = colorIdx % DISTRICT_COLORS.length;
            colorIdx++;
        });

        // For District view, the focal IS the district
        const expandedIds = this.contextRecordType === 'District'
            ? (this.expandedDistricts.has(this.recordId) ? [this.recordId] : [])
            : Array.from(this.expandedDistricts);

        expandedIds.forEach((districtId) => {
            const districtData = this.schoolsByDistrict[districtId];
            if (!districtData || !districtData.schools || districtData.schools.length === 0) return;

            const ci = districtColorMap[districtId] !== undefined
                ? districtColorMap[districtId]
                : 0;
            const dColor = DISTRICT_COLORS[ci];

            groups.push({
                districtId,
                districtName: districtData.name,
                accentColor: dColor.accent,
                headerStyle: `background: ${dColor.light}; border-left: 4px solid ${dColor.accent}; color: ${dColor.text};`,
                dotStyle: `color: ${dColor.accent};`,
                schools: districtData.schools.map((s) => ({
                    id: s.id,
                    name: s.name,
                    cardClass: 'node-card node-card-sm node-card-school-colored',
                    cardStyle: `border-left: 3px solid ${dColor.accent};`,
                    iconStyle: `background-color: ${dColor.accent};`,
                    icon: ICON_MAP.School
                }))
            });
        });

        return groups;
    }

    // ─── Wire ────────────────────────────────────────────────────────────
    @wire(getHierarchyData, { accountId: '$recordId' })
    wiredHierarchy(result) {
        this.isLoading = true;
        if (result.data) {
            this.contextRecordType = result.data.contextRecordType;
            this.contextAccountName = result.data.contextAccountName;
            this.parentEntities = this._mapChildrenKeys(
                JSON.parse(JSON.stringify(result.data.parentEntities || []))
            );
            this.childEntities = this._mapChildrenKeys(
                JSON.parse(JSON.stringify(result.data.childEntities || []))
            );
            this.error = null;
            this.isLoading = false;
        } else if (result.error) {
            this.error = result.error;
            this.parentEntities = [];
            this.childEntities = [];
            this.isLoading = false;
        }
    }

    // ─── Handlers ────────────────────────────────────────────────────────
    handleFilterToggle(event) {
        const value = event.currentTarget.dataset.value;
        const updated = new Set(this.activeFilters);
        if (updated.has(value)) {
            updated.delete(value);
        } else {
            updated.add(value);
        }
        this.activeFilters = updated;
    }

    handleClearFilters() {
        this.activeFilters = new Set();
    }

    handleSchoolsToggle(event) {
        this.showSchools = event.target.checked;
        if (!this.showSchools) {
            this.expandedDistricts = new Set();
        }
    }

    handleExpandSchools(event) {
        event.stopPropagation();
        const districtId = event.currentTarget.dataset.districtId;
        const updated = new Set(this.expandedDistricts);

        if (updated.has(districtId)) {
            updated.delete(districtId);
        } else {
            updated.add(districtId);
            // Load schools for this district if not already loaded
            if (!this.schoolsByDistrict[districtId]) {
                this._loadSchoolsForDistrict(districtId);
            }
        }
        this.expandedDistricts = updated;
    }

    handleNodeClick(event) {
        const accountId = event.currentTarget.dataset.id;
        if (accountId && accountId !== this.recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: accountId,
                    objectApiName: 'Account',
                    actionName: 'view'
                }
            });
        }
    }

    // ─── Private helpers ─────────────────────────────────────────────────

    _filteredParents() {
        if (!this.parentEntities) return [];
        if (this.contextRecordType === 'School') return this.parentEntities;
        if (this.activeFilters.size === 0) return this.parentEntities;
        return this.parentEntities.filter((node) => {
            if (!node.relationshipTypes) return false;
            const nodeTypes = node.relationshipTypes.split(';').map((t) => t.trim());
            return nodeTypes.some((t) => this.activeFilters.has(t));
        });
    }

    _filteredChildren() {
        if (!this.childEntities) return [];
        if (this.activeFilters.size === 0) return this.childEntities;
        return this.childEntities.filter((node) => {
            if (!node.relationshipTypes) return false;
            const nodeTypes = node.relationshipTypes.split(';').map((t) => t.trim());
            return nodeTypes.some((t) => this.activeFilters.has(t));
        });
    }

    _filterByType(nodes) {
        if (!nodes) return [];
        if (this.activeFilters.size === 0) return nodes;
        return nodes.filter((node) => {
            if (!node.relationshipTypes) return false;
            const nodeTypes = node.relationshipTypes.split(';').map((t) => t.trim());
            return nodeTypes.some((t) => this.activeFilters.has(t));
        });
    }

    _getGrandchildren() {
        const seen = new Map();
        const children = this._filteredChildren();
        children.forEach((child) => {
            const grandkids = this._filterByType(child._children || []);
            grandkids.forEach((gk) => {
                if (!seen.has(gk.id)) {
                    seen.set(gk.id, { ...gk, sourceLabel: child.name });
                }
            });
        });
        return Array.from(seen.values());
    }

    _getAllDistrictIds() {
        const ids = [];
        const seen = new Set();
        const addDistrict = (c) => {
            if (c.recordType === 'District' && !seen.has(c.id)) {
                seen.add(c.id);
                ids.push(c.id);
            }
        };
        // The focal account itself if District
        if (this.contextRecordType === 'District') {
            ids.push(this.recordId);
            seen.add(this.recordId);
        }
        (this.childEntities || []).forEach((c) => {
            addDistrict(c);
            (c._children || []).forEach((gc) => addDistrict(gc));
        });
        return ids;
    }

    _getSchoolCountForDistrict(districtId) {
        const data = this.schoolsByDistrict[districtId];
        return data ? data.schools.length : 0;
    }

    _loadSchoolsForDistrict(districtId) {
        this.isLoadingChildren = true;

        // Find the district name
        let districtName = '';
        if (this.contextRecordType === 'District' && districtId === this.recordId) {
            districtName = this.contextAccountName;
        } else {
            const allDistricts = [
                ...this._filteredChildren().filter((c) => c.recordType === 'District'),
                ...this._getGrandchildren().filter((c) => c.recordType === 'District')
            ];
            const found = allDistricts.find((d) => d.id === districtId);
            if (found) districtName = found.name;
        }

        getChildSchools({ districtId })
            .then((schools) => {
                const updated = { ...this.schoolsByDistrict };
                updated[districtId] = {
                    name: districtName,
                    schools: schools.map((s) => ({ ...s, _children: [] }))
                };
                this.schoolsByDistrict = updated;
                this.isLoadingChildren = false;
            })
            .catch((err) => {
                console.error('Error loading schools for district:', err);
                this.isLoadingChildren = false;
            });
    }

    _buildCardNode(node, isSmall = false) {
        const rt = node.recordType || 'District';
        const colors = COLOR_MAP[rt] || COLOR_MAP.District;
        const relTypes = node.relationshipTypes
            ? node.relationshipTypes.split(';').map((t) => t.trim()).filter((t) => t)
            : [];

        return {
            id: node.id,
            name: node.name,
            icon: ICON_MAP[rt] || 'standard:account',
            typeLabel: LABEL_MAP[rt] || rt,
            cardClass: isSmall ? 'node-card node-card-sm' : 'node-card',
            iconStyle: `background-color: ${colors.bg};`,
            badgeStyle: `background-color: ${colors.light}; color: ${colors.text}; border: 1px solid ${colors.border};`,
            hasRelTypes: relTypes.length > 0,
            relTypePills: relTypes,
            sourceLabel: node.sourceLabel || null,
            stripeStyle: '',
            hasSchoolExpander: false,
            isExpanded: false,
            expandIcon: 'utility:chevronright',
            expandLabel: 'Show Schools',
            schoolCount: 0,
            isLoadingSchools: false
        };
    }

    _extractAllRelationshipTypes() {
        const types = new Set();

        const extract = (nodes) => {
            if (!nodes) return;
            nodes.forEach((node) => {
                if (node.relationshipTypes) {
                    node.relationshipTypes.split(';').map((t) => t.trim()).filter((t) => t)
                        .forEach((t) => types.add(t));
                }
                if (node._children && node._children.length > 0) {
                    extract(node._children);
                }
            });
        };

        extract(this.parentEntities);
        extract(this.childEntities);
        return Array.from(types).sort();
    }

    _mapChildrenKeys(nodes) {
        if (!nodes || !Array.isArray(nodes)) return [];
        return nodes.map((node) => {
            const mapped = { ...node };
            if (mapped.children && Array.isArray(mapped.children)) {
                mapped._children = this._mapChildrenKeys(mapped.children);
                delete mapped.children;
            }
            return mapped;
        });
    }
}
