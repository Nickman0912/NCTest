/**
 * @description RFP Deep Dive LWC. Lets estimators ask natural-language
 *              questions about an RFP's ingested bid documents. Questions
 *              are proxied through RFPDeepDiveController to the Cloud Run
 *              RAG endpoint; answers come back with source citations.
 */
import { LightningElement, api, track, wire } from "lwc";
import { getRecord, getFieldValue } from "lightning/uiRecordApi";
import PORTAL_URL_FIELD from "@salesforce/schema/RFP__c.Portal_URL__c";
import ask from "@salesforce/apex/RFPDeepDiveController.ask";
import isConfigured from "@salesforce/apex/RFPDeepDiveController.isConfigured";
import getUploadUrl from "@salesforce/apex/RFPDeepDiveController.getUploadUrl";
import ingestDocument from "@salesforce/apex/RFPDeepDiveController.ingestDocument";
import getIngestStatus from "@salesforce/apex/RFPDeepDiveController.getIngestStatus";
import getDocuments from "@salesforce/apex/RFPDeepDiveController.getDocuments";
import summarize from "@salesforce/apex/RFPDeepDiveController.summarize";

export default class RfpDeepDive extends LightningElement {
  @api recordId;

  @track messages = [];
  @track draft = "";
  @track configured = true;
  @track uploads = [];
  @track documents = [];

  isThinking = false;
  isSummarizing = false;
  _nextId = 1;

  @wire(getRecord, { recordId: "$recordId", fields: [PORTAL_URL_FIELD] })
  _rfp;

  get portalUrl() {
    return getFieldValue(this._rfp?.data, PORTAL_URL_FIELD);
  }

  get hasPortalUrl() {
    return !!this.portalUrl;
  }

  get hasDocuments() {
    return this.documents.length > 0;
  }

  get chatDisabled() {
    return !this.hasDocuments;
  }

  get inputPlaceholder() {
    return this.hasDocuments
      ? "e.g. What are the liquidated damages?"
      : "Upload at least one document to start asking questions";
  }

  suggestedQuestions = [
    "What are the liquidated damages?",
    "What are the insurance requirements?",
    "What fire suppression systems are required?",
    "What is the substantial completion date?"
  ];

  connectedCallback() {
    isConfigured()
      .then((result) => {
        this.configured = result;
      })
      .catch(() => {
        this.configured = false;
      });
    this._loadDocuments();
  }

  async _loadDocuments() {
    try {
      const resp = await getDocuments({ rfpId: this.recordId });
      if (resp.success) {
        this.documents = (resp.documents || []).map((d, i) => ({
          key: `doc-${i}`,
          filename: d.filename,
          chunks: d.chunks,
          label: `${d.filename} (${d.chunks} sections)`
        }));
      }
    } catch (e) {
      // Non-fatal: the list just stays empty and chat stays gated.
      // eslint-disable-next-line no-console
      console.warn("Could not load documents", e);
    }
  }

  get showConfigWarning() {
    return !this.configured;
  }

  get hasMessages() {
    return this.messages.length > 0;
  }

  get sendDisabled() {
    return this.isThinking || !this.draft.trim() || this.chatDisabled;
  }

  get summaryButtonLabel() {
    return this.isSummarizing ? "Generating…" : "Generate Summary";
  }

  get summaryDisabled() {
    return this.isSummarizing || this.chatDisabled;
  }

  get qaDisabled() {
    return this.isThinking || this.chatDisabled;
  }

  // Ethereal avatar state: shifts the orb's colors + animation speed
  // while the assistant is thinking or writing.
  get avatarState() {
    return this.isThinking || this.isSummarizing ? "thinking" : "idle";
  }

  get avatarLabel() {
    if (this.isSummarizing) return "Summarizing";
    if (this.isThinking) return "Thinking";
    return this.hasDocuments ? "Ready" : "Idle";
  }

  handleInput(event) {
    this.draft = event.target.value;
  }

  _clearInput() {
    // The bound property alone doesn't always repaint the textarea, so
    // reset the element directly too.
    const box = this.template.querySelector(".input-box");
    if (box) box.value = "";
  }

  handleKeyDown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.handleSend();
    }
  }

  handleSuggested(event) {
    this.draft = event.target.dataset.question;
    this.handleSend();
  }

  async handleSend() {
    const question = this.draft.trim();
    if (!question || this.isThinking || this.chatDisabled) return;

    this._pushMessage("user", question);
    this.draft = "";
    this._clearInput();
    this.isThinking = true;

    try {
      const resp = await ask({ rfpId: this.recordId, question });
      if (resp.success) {
        this._pushMessage("ai", resp.answer, resp.citations);
      } else {
        this._pushMessage("ai", "Error: " + resp.errorMessage);
      }
    } catch (e) {
      this._pushMessage("ai", "Error: " + (e.body?.message || e.message));
    } finally {
      this.isThinking = false;
      this._scrollToBottom();
    }
  }

  async handleSummarize() {
    if (this.isSummarizing || this.chatDisabled) return;
    this.isSummarizing = true;
    this._pushMessage("user", "Generate a project summary and recommendation.");
    try {
      const resp = await summarize({ rfpId: this.recordId });
      if (resp.success) {
        this._pushMessage("ai", resp.summary, resp.citations);
      } else {
        this._pushMessage("ai", "Error: " + resp.errorMessage);
      }
    } catch (e) {
      this._pushMessage("ai", "Error: " + (e.body?.message || e.message));
    } finally {
      this.isSummarizing = false;
      this._scrollToBottom();
    }
  }

  async handleFileChange(event) {
    const input = event.target; // capture now; event.target is null after awaits
    const files = input.files;
    if (!files || !files.length) return;
    for (const file of files) {
      await this._uploadOne(file);
    }
    // Reset the input so the same file can be re-selected if needed.
    input.value = "";
  }

  async _uploadOne(file) {
    const upload = {
      key: `${Date.now()}-${file.name}`,
      name: file.name,
      status: "Requesting upload URL…",
      done: false,
      error: false,
      statusClass: "upload-status"
    };
    this.uploads.push(upload);
    try {
      const urlResp = await getUploadUrl({
        rfpId: this.recordId,
        filename: file.name,
        contentType: file.type || "application/octet-stream"
      });
      if (!urlResp.success) throw new Error(urlResp.errorMessage);

      upload.status = "Uploading to storage…";
      const put = await fetch(urlResp.uploadUrl, {
        method: "PUT",
        headers: { "Content-Type": file.type || "application/octet-stream" },
        body: file
      });
      if (!put.ok) throw new Error(`Upload failed (${put.status})`);

      upload.status = "Ingesting into AI index…";
      this.uploads = [...this.uploads];
      const ing = await ingestDocument({
        rfpId: this.recordId,
        filename: file.name,
        gcsPath: urlResp.gcsPath
      });
      if (!ing.success) throw new Error(ing.errorMessage || "Ingestion failed");

      if (ing.status === "ingested") {
        // Small doc finished synchronously.
        this._markReady(upload, ing.chunks);
      } else {
        // Large doc: poll the background job until it completes.
        await this._pollIngest(upload, file.name);
      }
    } catch (e) {
      upload.status = "Error: " + (e.body?.message || e.message);
      upload.error = true;
      upload.statusClass = "upload-status err";
    }
    // Trigger reactivity for the mutated object.
    this.uploads = [...this.uploads];
  }

  _markReady(upload, chunks) {
    upload.status = `Ready — ${chunks} chunks indexed`;
    upload.done = true;
    upload.statusClass = "upload-status ok";
    this.uploads = [...this.uploads];
    // Refresh the ingested-documents list so the new file shows up and
    // chat unlocks.
    this._loadDocuments();
  }

  async _pollIngest(upload, filename) {
    const maxAttempts = 60; // ~5 minutes at 5s intervals
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      await new Promise((r) => setTimeout(r, 5000));
      const st = await getIngestStatus({ rfpId: this.recordId, filename });
      if (!st.success) continue; // transient; keep polling
      if (st.status === "ingested") {
        this._markReady(upload, st.chunks);
        return;
      }
      if (st.status === "skipped") {
        upload.status = `Skipped — ${st.reason || "unsupported"}`;
        upload.done = true;
        upload.statusClass = "upload-status warn";
        this.uploads = [...this.uploads];
        return;
      }
      if (st.status === "error") {
        throw new Error(st.reason || "Ingestion failed");
      }
      // else still 'processing' / 'unknown' -> keep waiting
    }
    throw new Error("Timed out waiting for ingestion to finish");
  }

  _pushMessage(role, text, citations) {
    const msgId = this._nextId++;
    const cits = (citations || []).map((c, i) => ({
      key: `${msgId}-${i}`,
      file: c.file,
      chunk: c.chunk,
      excerpt: c.excerpt
    }));
    this.messages.push({
      id: msgId,
      rowClass: role === "user" ? "msg-row msg-user" : "msg-row msg-ai",
      text,
      citations: cits,
      hasCitations: cits.length > 0,
      citationsExpanded: false,
      citationToggleLabel: `Show ${cits.length} source${cits.length === 1 ? "" : "s"}`,
      citationCount: cits.length
    });
    this._scrollToBottom();
  }

  handleToggleCitations(event) {
    const msgId = Number(event.currentTarget.dataset.msgid);
    this.messages = this.messages.map((m) => {
      if (m.id !== msgId) return m;
      const expanded = !m.citationsExpanded;
      return {
        ...m,
        citationsExpanded: expanded,
        citationToggleLabel: expanded
          ? "Hide sources"
          : `Show ${m.citationCount} source${m.citationCount === 1 ? "" : "s"}`
      };
    });
  }

  _scrollToBottom() {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      const thread = this.template.querySelector('[data-element="chatThread"]');
      if (thread) thread.scrollTop = thread.scrollHeight;
    }, 50);
  }
}
