/**
 * @description Inside Sales AI assistant LWC.
 *              Features a glowing animated AI orb, a chat thread,
 *              quick actions, and OpenRouter-backed natural-language
 *              analysis of the current Account.
 */
import { LightningElement, api, track } from 'lwc';

/** Fetch the account context and chat methods from the controller. */
import getAccountContext from '@salesforce/apex/InsideSalesAIController.getAccountContext';
import chat from '@salesforce/apex/InsideSalesAIController.chat';
import createRenewalOpportunity from '@salesforce/apex/InsideSalesAIController.createRenewalOpportunity';
import ensureGeocoded from '@salesforce/apex/InsideSalesAIController.ensureGeocoded';

export default class InsideSalesAI extends LightningElement {
    @api recordId;

    /** Chat thread messages. */
    @track messages = [];
    @track draft = '';

    /** Orb state: idle | thinking | speaking | error */
    orbState = 'idle';
    orbStatusText = 'Ready';

    /** Whether the AI is currently generating a reply. */
    isThinking = false;
    isSpeaking = false;
    welcomeShowing = true;

    /** Whether the widget body is collapsed (only header visible). */
    isCollapsed = true;

    /** AI model name (from metadata config). */
    @track modelName = '';
    @track configReady = false;

    /** Conversation history passed to the controller. */
    conversationHistory = [];

    /** Orb animation frame handle. */
    _animFrame = null;
    _particles = [];
    _orbCtx = null;
    _lastTick = 0;
    _isCanvasMounted = false;
    _accountName = 'this account';

    /* ================= LIFECYCLE ================= */

    connectedCallback() {
        // Kick off geocoding for this account in its own transaction so
        // distances to other schools are cached before the user chats.
        // (Fire-and-forget; failures are silent and distances are simply omitted.)
        ensureGeocoded({ accountId: this.recordId }).catch(() => {});

        // Fetch account context to determine config/model status.
        this._loadContext();
    }

    disconnectedCallback() {
        this._stopOrb();
    }

    /** Loads the account context (mainly for model name + config status). */
    async _loadContext() {
        try {
            const ctx = await getAccountContext({ accountId: this.recordId });
            this.configReady = ctx.configReady;
            this.modelName = ctx.configModel || 'AI';
            if (ctx.accountName) {
                this._accountName = ctx.accountName;
            }
        } catch (e) {
            this.configReady = false;
            this.modelName = '';
        }
    }

    /* ================= GETTERS ================= */

    /** Whether the model has been configured (used to show status badge). */
    get modelReady() {
        return this.configReady;
    }

    /* ================= RENDERED CALLBACK (start orb) ================= */

    renderedCallback() {
        if (!this._isCanvasMounted) {
            this._isCanvasMounted = true;
            this._startOrb();
        }
    }

    /* ================= ORB ANIMATION ================= */

    _startOrb() {
        const canvas = this.template.querySelector('[data-element="orbCanvas"]');
        if (!canvas) return;

        this._orbCtx = canvas.getContext('2d');
        canvas.width = 160;
        canvas.height = 160;

        // Initialize a stable particle field.
        this._particles = [];
        for (let i = 0; i < 70; i++) {
            this._particles.push({
                angle: Math.random() * Math.PI * 2,
                radius: 26 + Math.random() * 48,
                speed: 0.002 + Math.random() * 0.006,
                size: 1 + Math.random() * 2.2,
                alpha: 0.4 + Math.random() * 0.6,
                pulsePhase: Math.random() * Math.PI * 2,
            });
        }

        this._lastTick = performance.now();
        this._animFrame = requestAnimationFrame(this._tick.bind(this));
    }

    _tick(ts) {
        if (!this._orbCtx) return;
        const ctx = this._orbCtx;
        const dt = ts - this._lastTick;
        this._lastTick = ts;

        ctx.clearRect(0, 0, 160, 160);

        // State-based color & speed.
        let targetColor = [99, 102, 241]; // indigo (idle)
        let driftSpeed = 0.15;
        if (this.orbState === 'thinking') {
            targetColor = [249, 115, 22]; // orange
            driftSpeed = 0.5;
        } else if (this.orbState === 'speaking') {
            targetColor = [16, 185, 129]; // teal
            driftSpeed = 0.35;
        } else if (this.orbState === 'error') {
            targetColor = [239, 68, 68]; // red
            driftSpeed = 0.2;
        }

        // Draw the core glow (radial gradient).
        const t = ts / 1000;
        const pulse = 0.8 + 0.2 * Math.sin(t * 2);
        const coreRadius = 34 * pulse;
        const grad = ctx.createRadialGradient(80, 80, 2, 80, 80, coreRadius + 14);
        grad.addColorStop(0, `rgba(${targetColor[0]},${targetColor[1]},${targetColor[2]},1)`);
        grad.addColorStop(0.7, `rgba(${targetColor[0]},${targetColor[1]},${targetColor[2]},0.55)`);
        grad.addColorStop(1, `rgba(${targetColor[0]},${targetColor[1]},${targetColor[2]},0)`);
        ctx.beginPath();
        ctx.arc(80, 80, coreRadius + 14, 0, Math.PI * 2);
        ctx.fillStyle = grad;
        ctx.fill();

        // Draw orbiting particles.
        for (const p of this._particles) {
            p.angle += (p.speed * (this.orbState === 'thinking' ? 3 : 1) * driftSpeed * 10) / 1000;
            const x = 80 + Math.cos(p.angle) * p.radius;
            const y = 80 + Math.sin(p.angle) * p.radius;
            const twinkle = 0.6 + 0.4 * Math.sin(t * 3 + p.pulsePhase);
            ctx.beginPath();
            ctx.arc(x, y, p.size, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(${targetColor[0]},${targetColor[1]},${targetColor[2]},${p.alpha * twinkle})`;
            ctx.fill();
        }

        this._animFrame = requestAnimationFrame(this._tick.bind(this));
    }

    _stopOrb() {
        if (this._animFrame) {
            cancelAnimationFrame(this._animFrame);
            this._animFrame = null;
        }
    }

    setOrbState(state, statusText) {
        this.orbState = state;
        this.orbStatusText = statusText;
        this.isSpeaking = state === 'speaking';
    }

    /* ================= COLLAPSE / EXPAND ================= */

    /** Toggle icon based on collapsed state. */
    get toggleIcon() {
        return this.isCollapsed ? 'utility:chevronup' : 'utility:chevrondown';
    }

    /** Accessible label for the toggle. */
    get toggleLabel() {
        return this.isCollapsed ? 'Expand Raptor AI' : 'Collapse Raptor AI';
    }

    /** Toggle the collapsed state when the header is clicked. */
    handleToggleCollapse() {
        this.isCollapsed = !this.isCollapsed;
        // If expanding, re-focus the input box.
        if (!this.isCollapsed) {
            // Defer so the DOM has rendered the body back.
            requestAnimationFrame(() => {
                const box = this.template.querySelector('[data-element="inputBox"]');
                if (box) {
                    box.focus();
                }
            });
        }
    }

    /** Allow keyboard access (Enter/Space) on the header toggle. */
    handleHeaderKeyDown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleToggleCollapse();
        }
    }

    /* ================= INPUT HANDLING ================= */

    handleInput(event) {
        this.draft = event.target.value;
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.handleSend();
        }
    }

    /* ================= QUICK ACTIONS ================= */

    handleWhitespaceClick() {
        this._sendMessage(
            `Analyze the whitespace opportunities for ${this._accountName}. ` +
                `Compare the assets this account has against the full product catalog and identify ` +
                `which products they don't yet have.`
        );
    }

    handleAssetsClick() {
        this._sendMessage(
            `Give me a full status report on all the assets this account owns: which products they have, ` +
                `who paid for them, when they expire, and which ones need renewal soonest.`
        );
    }

    handleNearbyClick() {
        this._sendMessage(
            `Show me other schools geographically near this one that are similar in characteristics ` +
                `but do not already have the products this school purchased independently. Highlight the ` +
                `best whitespace expansion targets.`
        );
    }

    /* ================= SEND ================= */

    handleSend() {
        const msg = this.draft && this.draft.trim();
        if (!msg || this.isThinking) return;
        this.draft = '';
        // Explicitly clear the textarea DOM element so the typed message
        // doesn't persist in the input box after sending.
        const box = this.template.querySelector('[data-element="inputBox"]');
        if (box) {
            box.value = '';
        }
        this._sendMessage(msg);
    }

    async _sendMessage(textMessage) {
        const userMsg = {
            id: `u-${Date.now()}`,
            text: textMessage,
            isUser: true,
            rowClass: 'msg-row msg-user',
        };
        this.messages = [...this.messages, userMsg];
        // The controller appends the current userMessage itself, so send the
        // history WITHOUT the just-added message to avoid sending it twice.
        const historyToSend = [
            ...this.conversationHistory,
            { role: 'user', content: textMessage },
        ];
        this.conversationHistory = historyToSend;
        this.welcomeShowing = false;
        this.isThinking = true;
        this.setOrbState('thinking', 'Thinking…');

        // Scroll to bottom.
        this._scrollToBottom();

        try {
            const resp = await chat({
                accountId: this.recordId,
                userMessage: textMessage,
                conversationHistoryJson: JSON.stringify(
                    historyToSend.slice(0, historyToSend.length - 1)
                ),
            });

            // Check if the AI requested a renewal opportunity creation.
            const renewalMarker = resp.reply.match(/\[CREATE_RENEWAL:([^\]]+)\]/);
            let finalReply = resp.reply;
            if (renewalMarker) {
                // Strip the marker from the visible reply.
                finalReply = resp.reply.replace(/\[CREATE_RENEWAL:[^\]]+\]/, '').trim();

                // Parse the asset IDs from the marker.
                const assetIds = renewalMarker[1]
                    .split(',')
                    .map((id) => id.trim())
                    .filter((id) => id.length > 0);

                // Create the renewal opportunity.
                const renewalResult = await createRenewalOpportunity({
                    accountId: this.recordId,
                    assetIds,
                });

                // Send the result back to the AI for a conversational acknowledgment.
                const followUp = await chat({
                    accountId: this.recordId,
                    userMessage:
                        `The renewal opportunity creation was ${renewalResult.success ? 'successful' : 'unsuccessful'}. ` +
                        `Result: ${renewalResult.message}. ` +
                        `Please acknowledge this result conversationally to the user.`,
                    conversationHistoryJson: JSON.stringify([
                        ...this.conversationHistory,
                        { role: 'assistant', content: resp.reply },
                    ]),
                });

                finalReply = finalReply
                    ? `${finalReply}\n\n${followUp.reply}`
                    : followUp.reply;

                // Update conversation history with the follow-up.
                this.conversationHistory = [
                    ...this.conversationHistory,
                    { role: 'assistant', content: resp.reply },
                    { role: 'user', content: 'Renewal creation result received.' },
                    { role: 'assistant', content: followUp.reply },
                ];
            } else {
                this.conversationHistory = [
                    ...this.conversationHistory,
                    { role: 'assistant', content: resp.reply },
                ];
            }

            const aiMsg = {
                id: `a-${Date.now()}`,
                text: finalReply,
                isUser: false,
                rowClass: 'msg-row msg-ai',
            };
            this.messages = [...this.messages, aiMsg];
            this.setOrbState('speaking', 'Done');
            // After a brief "speaking" state, return to idle.
            setTimeout(() => this.setOrbState('idle', 'Ready'), 1500);
        } catch (e) {
            const errMsg =
                e && e.body && e.body.message
                    ? e.body.message
                    : 'Sorry, the AI is not available right now.';
            const aiMsg = {
                id: `a-${Date.now()}`,
                text: errMsg,
                isUser: false,
                rowClass: 'msg-row msg-ai',
            };
            this.messages = [...this.messages, aiMsg];
            this.setOrbState('error', 'Error');
            setTimeout(() => this.setOrbState('idle', 'Ready'), 2000);
        } finally {
            this.isThinking = false;
        }
    }

    _scrollToBottom() {
        // Defer so the new message has rendered.
        requestAnimationFrame(() => {
            const thread = this.template.querySelector('[data-element="chatThread"]');
            if (thread) {
                thread.scrollTop = thread.scrollHeight;
            }
            const box = this.template.querySelector('[data-element="inputBox"]');
            if (box) {
                box.focus();
            }
        });
    }
}