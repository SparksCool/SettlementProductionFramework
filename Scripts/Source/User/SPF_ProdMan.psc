Scriptname SPF_ProdMan extends Quest

WorkshopParentScript Property WorkshopParent Auto Const Mandatory

Bool Property bOverrideOutputWorkshop = False Auto

String[] Property LedgerContent Auto

Group Settings

GlobalVariable Property CostsDisabled Auto Const
GlobalVariable Property WageAmount Auto Const
GlobalVariable Property WagesEnabled Auto Const
GlobalVariable Property WagePenalty Auto Const
GlobalVariable Property Work24Hours Auto Const
GlobalVariable Property ChargePlayerCaps Auto Const
GlobalVariable Property CapsDonationAmount Auto Const
GlobalVariable Property TickHoursOverride Auto Const
GlobalVariable Property ProductionMultiplierOverride Auto Const
GlobalVariable Property ConsumptionMultiplierOverride Auto Const

EndGroup

Group Internal

WorkshopScript Property OutputWorkshop Auto
Float Property TickHours = 24.0 Auto
Float Property now = 0.0 Auto Hidden
RefCollectionAlias Property PersistentProducers Auto

EndGroup    

Bool Property needsReload = False Auto Hidden
Bool Property needsFullReload = False Auto Hidden

Group Ledger
Message Property LedgerMessage Auto              ; message form created in CK with 2 buttons: Next (0), Exit (1)
string[] Property LedgerContents Auto            ; will be filled by this function for MCM display if you want
ReferenceAlias Property LedgerText Auto
EndGroup

; Replaced array with FormList
FormList Property ProducerList Auto
FormList Property TempList Auto ; Temporary storage for producers when cleaning up

Int Property _TickTimerID = 1001 Auto Const

; Non property variables
Float productionMultiplier = 1.0
Float consumptionMultiplier = 1.0

Function RegisterProducer(SPF_ProdObj obj)
    If obj == None
        Return
    EndIf
    If ProducerList == None
        Debug.Trace("[SPF_ProdMan] RegisterProducer: ProducerList property not set")
        Return
    EndIf
    If !ProducerList.HasForm(obj as Form)
        ProducerList.AddForm(obj as Form)
        ; Add to persistent alias if possible
        if PersistentProducers != None
            ObjectReference objRef = obj as ObjectReference
            if objRef != None && !PersistentProducersContains(objRef)
                PersistentProducers.AddRef(objRef)
                Debug.Trace("[SPF_ProdMan] RegisterProducer: Added to PersistentProducers alias")
            endif
        Else
            Debug.MessageBox("Warning: PersistentProducers alias not set, this producer will not persist across cell unload/load")
        endif
    EndIf
EndFunction

Function UnregisterProducer(SPF_ProdObj obj)
    If obj == None
        Return
    EndIf
    If ProducerList == None
        Debug.Trace("[SPF_ProdMan] UnregisterProducer: ProducerList property not set")
        Return
    EndIf
    ; Remove only works for runtime-added forms
    ProducerList.RemoveAddedForm(obj as Form)
    ; Remove from persistent alias if possible
    if PersistentProducers != None
        ObjectReference objRef = obj as ObjectReference
        if objRef != None && PersistentProducersContains(objRef)
            PersistentProducers.RemoveRef(objRef)
            Debug.Trace("[SPF_ProdMan] UnregisterProducer: Removed from PersistentProducers alias")
        endif
    endif
EndFunction

Function donateCaps()
    MiscObject CapsItem = Game.GetFormFromFile(0x0000000F, "Fallout4.esm") as MiscObject
    ObjectReference currentWorkshopContainer = WorkshopParent.GetWorkshop(WorkshopParent.WorkshopCurrentWorkshopID.GetValueInt()) as ObjectReference
    ObjectReference playerRef = Game.GetPlayer()
    int donationAmount = CapsDonationAmount.GetValueInt()

    ; Check if the workshop exists
    if currentWorkshopContainer == None
        Debug.MessageBox("You are not at a workshop location.")
        return
    endif

    int playerCaps = playerRef.GetItemCount(CapsItem)

    if playerCaps >= donationAmount
        playerRef.RemoveItem(CapsItem, donationAmount, True)
        currentWorkshopContainer.AddItem(CapsItem, donationAmount, True)
        Debug.MessageBox(donationAmount + " Caps Donated")
    else
        int missingCaps = donationAmount - playerCaps
        Debug.MessageBox("Insufficient Funds, missing " + missingCaps + " Caps")
    endif
EndFunction

Function reloadMod()
    Debug.MessageBox("Production will reload variables next cycle!")
    needsReload = True
EndFunction

Function fullReloadMod()
    Debug.MessageBox("Production will completely reset variables next cycle!")
    needsReload = True
    needsFullReload = True
EndFunction

Bool Function ConsumeFromNetwork(WorkshopScript rootWorkshop, Form[] reqForms, Int[] reqCounts)
    If rootWorkshop == None || reqForms == None || reqCounts == None
        Return False
    EndIf
    If reqForms.Length != reqCounts.Length
        Return False
    EndIf
    if CostsDisabled.GetValueInt() > 0
        Debug.Trace("[SPF_ProdMan] ConsumeFromNetwork: costs are disabled, skipping consumption")
        Return True
    EndIf

    ObjectReference[] containers = GetNetworkContainers(rootWorkshop)
    If containers == None || containers.Length == 0
        Return False
    EndIf

    ; -------- First pass: availability check (components and normal items) --------
    Int i = 0
    While i < reqForms.Length
        Form req = reqForms[i]
        Int need = reqCounts[i]
        If req != None && need > 0
            Int totalHave = 0

            ; Try cast to Component - if successful, treat it as a component requirement
            Component compReq = req as Component
            If compReq != None
                Int j = 0
                While j < containers.Length
                    totalHave += containers[j].GetComponentCount(compReq)
                    j += 1
                EndWhile
            Else
                ; Normal item
                Int j = 0
                While j < containers.Length
                    totalHave += containers[j].GetItemCount(req)
                    j += 1
                EndWhile
            EndIf

            If totalHave < need
                ; Not enough of this requirement anywhere on the network -> abort
                Return False
            EndIf
        EndIf
        i += 1
    EndWhile

    ; -------- Second pass: perform actual removals --------
    i = 0
    While i < reqForms.Length
        Form req = reqForms[i]
        Int remaining = reqCounts[i]
        If req != None && remaining > 0
            Component compReq = req as Component
            Int j = 0
            While remaining > 0 && j < containers.Length
                If compReq != None
                    ; Component removal path
                    Int haveComp = containers[j].GetComponentCount(compReq)
                    If haveComp > 0
                        Int take = haveComp
                        If take > remaining
                            take = remaining
                        EndIf
                        ; RemoveComponents removes the component count from the container
                        containers[j].RemoveComponents(compReq, take, True)
                        remaining -= take
                    EndIf
                Else
                    ; Normal item removal path
                    Int haveItem = containers[j].GetItemCount(req)
                    If haveItem > 0
                        Int take = haveItem
                        If take > remaining
                            take = remaining
                        EndIf
                        ; RemoveItem signature: (Form, Int, Bool abSilent, ObjectReference akToContainer = None)
                        ; here we remove to 'None' (destroy/consume) and do it silently
                        containers[j].RemoveItem(req, take, True, None)
                        remaining -= take
                    EndIf
                EndIf
                j += 1
            EndWhile

            ; defensive check - this should not happen because we ran an availability pass earlier
            If remaining > 0
                Debug.Trace("[SPF_ProdMan] ConsumeFromNetwork: unexpected shortage while removing " + req + ", remaining=" + remaining)
                Return False
            EndIf
        EndIf
        i += 1
    EndWhile

    Return True
EndFunction

Bool Function ConsumeCapsFromNetwork(WorkshopScript rootWorkshop, Int capsAmount)
    If rootWorkshop == None || capsAmount <= 0
        Return False
    EndIf

    ; Handle the "costs disabled" setting
    If CostsDisabled.GetValueInt() > 0
        Debug.Trace("[SPF_ProdMan] ConsumeCapsFromNetwork: costs are disabled, skipping consumption")
        Return True
    EndIf

    ; Get caps form at runtime
    MiscObject capsForm = Game.GetFormFromFile(0x0000000F, "Fallout4.esm") as MiscObject
    If capsForm == None
        Debug.Trace("[SPF_ProdMan] ConsumeCapsFromNetwork: failed to get caps form")
        Return False
    EndIf

    ObjectReference[] containers = GetNetworkContainers(rootWorkshop)

    if ChargePlayerCaps.GetValueInt() > 0
        ObjectReference playerRef = Game.GetPlayer()
        if playerRef != none 
            containers = PushContainer(containers, playerRef)
        EndIf
    EndIf

    If containers == None || containers.Length == 0
        Return False
    EndIf

    ; -------- First pass: availability check --------
    Int totalHave = 0
    Int i = 0
    While i < containers.Length
        totalHave += containers[i].GetItemCount(capsForm)
        i += 1
    EndWhile

    If totalHave < capsAmount
        Return False ; not enough caps
    EndIf

    ; -------- Second pass: perform removals --------
    Int remaining = capsAmount
    i = 0
    While remaining > 0 && i < containers.Length
        Int haveCaps = containers[i].GetItemCount(capsForm)
        If haveCaps > 0
            Int take = haveCaps
            If take > remaining
                take = remaining
            EndIf
            containers[i].RemoveItem(capsForm, take, True, None)
            remaining -= take
        EndIf
        i += 1
    EndWhile

    If remaining > 0
        Debug.Trace("[SPF_ProdMan] ConsumeCapsFromNetwork: unexpected shortage, remaining=" + remaining)
        Return False
    EndIf

    Return True
EndFunction

Function AddOutputsTo(WorkshopScript targetWorkshop, Form[] outForms, Int[] outCounts)
    If targetWorkshop == None || outForms == None || outCounts == None || outForms.Length != outCounts.Length
        Return
    EndIf
    ObjectReference outCont = targetWorkshop.GetContainer()
    If outCont == None
        Return
    EndIf
    Int i = 0
    While i < outForms.Length
        Form f = outForms[i]
        Int c = outCounts[i]
        If f != None && c > 0
            outCont.AddItem(f, c, True)
        EndIf
        i += 1
    EndWhile
EndFunction

Event OnInit()
    StartTimerGameTime(TickHours, _TickTimerID)
EndEvent

Event OnTimerGameTime(Int aiTimerID)
    If aiTimerID == _TickTimerID
        Debug.Trace(self + " SPF_ProdMan: OnTimerGameTime tick")
        RunTick()
        Debug.Trace(self + " SPF_ProdMan: OnTimerGameTime tick complete")
        StartTimerGameTime(TickHours, _TickTimerID)
        Debug.Trace(self + " SPF_ProdMan: OnTimerGameTime timer restarted")
    EndIf
EndEvent

Function UpdateTickTimer()
    CancelTimerGameTime(_TickTimerID)
    StartTimerGameTime(TickHoursOverride.GetValueInt(), _TickTimerID)
    Debug.Trace(self + " SPF_ProdMan: UpdateTickTimer restarted timer with TickHoursOverride=" + TickHoursOverride.GetValueInt())
    TickHours = TickHoursOverride.GetValueInt()
EndFunction

Function UpdateMultipliers()
    if ProductionMultiplierOverride != None
        productionMultiplier = ProductionMultiplierOverride.GetValue()
    endif
    if ConsumptionMultiplierOverride != None
        consumptionMultiplier = ConsumptionMultiplierOverride.GetValue()
    endif
EndFunction

Float Function GetProductionMultiplier()
    Return productionMultiplier
EndFunction

Float Function GetConsumptionMultiplier()
    Return consumptionMultiplier
EndFunction

Function RunTick()

    ; Similar to the tickhours update, if these dont match then we need to update our multipliers for the next production tick
    if ((ProductionMultiplierOverride != None && productionMultiplier != ProductionMultiplierOverride.GetValue()) || (ConsumptionMultiplierOverride != None && consumptionMultiplier != ConsumptionMultiplierOverride.GetValue()))
        UpdateMultipliers()
    EndIf

    now = Utility.GetCurrentGameTime()

    If ProducerList == None
        ; nothing to do
        Return
    EndIf
    
    Int i = 0
    Int count = ProducerList.GetSize()
    Bool dirtyList = False ; track if we need to clean up the producer list
    While i < count
        SPF_ProdObj p = ProducerList.GetAt(i) as SPF_ProdObj
        If p == None
            count = ProducerList.GetSize()
            Debug.Trace(self + " SPF_ProdMan: RunTick found null producer, skipping and queuing for cleaning")
            dirtyList = True
            i += 1
        Else
            p.ProcessIfDue(self)
            i += 1
        EndIf
    EndWhile

    If dirtyList
        CleanProducerList()
    EndIf

    needsReload = False ; By this point all of the production objects will have gotten the signal to reload, any further reloading would hurt performance
    needsFullReload = False ; reset full reload flag

    SyncPersistentProducers() ; ensure the PersistentProducers alias is in sync with the ProducerList after any potential removals

    if (TickHoursOverride != None && TickHours != TickHoursOverride.GetValueInt()) ; if these dont match then we need to update the tick timer to match the override value
        UpdateTickTimer()
    EndIf
EndFunction

Function SyncPersistentProducers()
    Debug.Trace("[SPF_ProdMan] SyncPersistentProducers: Syncing PersistentProducers alias with ProducerList...")
    ; Clears PersistentProducers and fills it with all valid ObjectReferences from ProducerList
    if PersistentProducers == None || ProducerList == None
        Debug.Trace("[SPF_ProdMan] SyncPersistentProducers: Missing alias or formlist")
        return
    endif

    ; Remove all refs from the collection alias
    int aliasCount = PersistentProducers.GetCount()
    while aliasCount > 0
        ObjectReference refToRemove = PersistentProducers.GetAt(0)
        if refToRemove != None
            PersistentProducers.RemoveRef(refToRemove)
        endif
        aliasCount = PersistentProducers.GetCount()
    endwhile

    ; Add all valid ObjectReferences from ProducerList, skip invalid/duplicate refs
    int count = ProducerList.GetSize()
    int i = 0
    while i < count
        ObjectReference prodRef = ProducerList.GetAt(i) as ObjectReference
        if prodRef == None
            Debug.Trace("[SPF_ProdMan] SyncPersistentProducers: Skipped None ref at index " + i)
        elseif PersistentProducersContains(prodRef)
            Debug.Trace("[SPF_ProdMan] SyncPersistentProducers: Skipped duplicate ref at index " + i + ", FormID: " + prodRef.GetFormID())
        else
            PersistentProducers.AddRef(prodRef)
        endif
        i += 1
    endwhile
    Debug.Trace("[SPF_ProdMan] SyncPersistentProducers: Alias now has " + PersistentProducers.GetCount() + " refs")
EndFunction

; A custom search method for checking if an ObjectReference is already in the PersistentProducers alias, since the built-in find method was not working in my implementation, band-aid fix for now
Bool Function PersistentProducersContains(ObjectReference objRef)
    if PersistentProducers == None || objRef == None
        return False
    endif
    int count = PersistentProducers.GetCount()
    int i = 0
    while i < count
        ObjectReference ref = PersistentProducers.GetAt(i)
        if ref != None && ref.GetFormID() == objRef.GetFormID()
            Debug.Trace("[SPF_ProdMan] PersistentProducersContains: Found match at index " + i + ", FormID: " + ref.GetFormID())
            return True
        endif
        i += 1
    endwhile
    return False
EndFunction

Function CleanProducerList()
    Debug.Trace(self + " SPF_ProdMan: Cleaning ProducerList...")
    
    ; Create a temporary FormList to hold valid producers
    Int i = 0
    Int count = ProducerList.GetSize()
    
    While i < count
        Form f = ProducerList.GetAt(i)
        If f != None
            TempList.AddForm(f)
        Else
            Debug.Trace(self + " SPF_ProdMan: Found null producer at index " + i + ", skipping")
        EndIf
        i += 1
    EndWhile
    
    ; Clear the original ProducerList
    ProducerList.Revert()
    
    i = 0
    count = TempList.GetSize()
    While i < count
        ProducerList.AddForm(TempList.GetAt(i))
        i += 1
    EndWhile

    ; Revert the temporary list
    TempList.Revert()

    Debug.Trace(self + " SPF_ProdMan: ProducerList cleaned, size is now " + ProducerList.GetSize())
EndFunction

ObjectReference[] Function GetNetworkContainers(WorkshopScript rootWorkshop)
    ObjectReference[] list = new ObjectReference[0]
    If rootWorkshop == None
        Return list
    EndIf

    ObjectReference rootCont = rootWorkshop.GetContainer()
    If rootCont != None
        list = PushContainer(list, rootCont)
    EndIf

    Location rootLoc = rootWorkshop.myLocation
    If rootLoc != None && WorkshopParent != None
        Location[] links = rootLoc.GetAllLinkedLocations(WorkshopParent.WorkshopCaravanKeyword)
        Int k = 0
        While k < links.Length
            Int linkedId = WorkshopParent.WorkshopLocations.Find(links[k])
            If linkedId > 0
                WorkshopScript ws = WorkshopParent.GetWorkshop(linkedId)
                If ws != None
                    ObjectReference c = ws.GetContainer()
                    If c != None
                        list = PushContainer(list, c)
                    EndIf
                EndIf
            EndIf
            k += 1
        EndWhile
    EndIf

    Return list
EndFunction

Int Function FindProducer(SPF_ProdObj obj)
    If ProducerList == None || obj == None
        Return -1
    EndIf
    Return ProducerList.Find(obj as Form)
EndFunction

ObjectReference[] Function PushContainer(ObjectReference[] arr, ObjectReference item)
    Int n = 0
    If arr != None
        n = arr.Length
    EndIf
    ObjectReference[] tmp = new ObjectReference[n + 1]
    Int i = 0
    While i < n
        tmp[i] = arr[i]
        i += 1
    EndWhile
    tmp[n] = item
    Return tmp
EndFunction

; ==========================
; MCM & Logging Helper Functions (updated to use ProducerList)
; ==========================

string Function GetProducerNames()
    Float startTime = Utility.GetCurrentRealTime()

    Debug.MessageBox("Generating production report... This may take a while, please wait.")

    LedgerContents = new string[0]

    If ProducerList == None || ProducerList.GetSize() == 0
        LedgerContents = new string[1]
        LedgerContents[0] = "(none)"
        Debug.Trace("[SPF_ProdMan] GetProducerNames: no producers")
        Return LedgerContents[0]
    EndIf

    string[] uniqueNames = new string[0]
    Int pIdx = 0
    Int prodCount = ProducerList.GetSize()
    While pIdx < prodCount
        SPF_ProdObj p = ProducerList.GetAt(pIdx) as SPF_ProdObj
        If p != None
            ObjectReference pref = p as ObjectReference
            If pref != None
                string nm = pref.GetDisplayName()
                If nm == ""
                    nm = "(unnamed)"
                EndIf

                Bool foundName = False
                Int u = 0
                While u < uniqueNames.Length
                    If uniqueNames[u] == nm
                        foundName = True
                        u = uniqueNames.Length
                    EndIf
                    u += 1
                EndWhile

                If !foundName
                    Int curN = 0
                    If uniqueNames != None
                        curN = uniqueNames.Length
                    EndIf
                    string[] tmpN = new string[curN + 1]
                    Int ci = 0
                    While ci < curN
                        tmpN[ci] = uniqueNames[ci]
                        ci += 1
                    EndWhile
                    tmpN[curN] = nm
                    uniqueNames = tmpN
                EndIf
            EndIf
        EndIf
        pIdx += 1
    EndWhile

    ObjectReference[] allContainers = new ObjectReference[0]
    Int pp = 0
    prodCount = ProducerList.GetSize()
    While pp < prodCount
        SPF_ProdObj prod = ProducerList.GetAt(pp) as SPF_ProdObj
        If prod != None
            WorkshopScript owner = prod.GetOwningWorkshop()
            If owner != None
                ObjectReference[] conts = GetNetworkContainers(owner)
                If conts != None
                    Int ci = 0
                    While ci < conts.Length
                        ObjectReference cRef = conts[ci]
                        Bool found = False
                        Int fi = 0
                        While fi < allContainers.Length
                            If allContainers[fi] == cRef
                                found = True
                                fi = allContainers.Length
                            EndIf
                            fi += 1
                        EndWhile
                        If !found
                            Int oldC = 0
                            If allContainers != None
                                oldC = allContainers.Length
                            EndIf
                            ObjectReference[] tmpC = new ObjectReference[oldC + 1]
                            Int copyi = 0
                            While copyi < oldC
                                tmpC[copyi] = allContainers[copyi]
                                copyi += 1
                            EndWhile
                            tmpC[oldC] = cRef
                            allContainers = tmpC
                        EndIf
                        ci += 1
                    EndWhile
                EndIf
            EndIf
        EndIf
        pp += 1
    EndWhile

    Form[] totalNeedForms = new Form[0]
    Int[]  totalNeedCounts = new Int[0]

    string[] groupStrings = new string[0]
    Int gi = 0
    While gi < uniqueNames.Length
        string groupName = uniqueNames[gi]

        Int occ = 0
        Form[] outFormsAgg = new Form[0]
        Int[]  outCountsAgg = new Int[0]
        Form[] inFormsAgg = new Form[0]
        Int[]  inCountsAgg = new Int[0]

        Int scan = 0
        prodCount = ProducerList.GetSize()
        While scan < prodCount
            SPF_ProdObj sp = ProducerList.GetAt(scan) as SPF_ProdObj
            If sp != None
                ObjectReference rr = sp as ObjectReference
                If rr != None && rr.GetDisplayName() == groupName
                    occ += 1

                    Form[] outs = sp.FormsFromList(sp.OutputFormsList, True)
                    Int[] ocnts = sp.OutputCounts
                    If outs != None && ocnts != None && outs.Length == ocnts.Length
                        Int oi = 0
                        While oi < outs.Length
                            Form fOut = outs[oi]
                            Int add = ocnts[oi]
                            If fOut != None && add > 0
                                Int idx = -1
                                Int k = 0
                                While k < outFormsAgg.Length
                                    If outFormsAgg[k] == fOut
                                        idx = k
                                        k = outFormsAgg.Length
                                    EndIf
                                    k += 1
                                EndWhile

                                If idx == -1
                                    Int old = 0
                                    If outFormsAgg != None
                                        old = outFormsAgg.Length
                                    EndIf
                                    Form[] tmpF = new Form[old + 1]
                                    Int ci = 0
                                    While ci < old
                                        tmpF[ci] = outFormsAgg[ci]
                                        ci += 1
                                    EndWhile
                                    tmpF[old] = fOut
                                    outFormsAgg = tmpF

                                    Int[] tmpI = new Int[old + 1]
                                    ci = 0
                                    While ci < old
                                        tmpI[ci] = outCountsAgg[ci]
                                        ci += 1
                                    EndWhile
                                    tmpI[old] = add
                                    outCountsAgg = tmpI
                                Else
                                    outCountsAgg[idx] = outCountsAgg[idx] + add
                                EndIf
                            EndIf
                            oi += 1
                        EndWhile
                    EndIf

                    Form[] ins = sp.FormsFromList(sp.InputFormsList, False)
                    Int[] icnts = sp.InputCounts
                    If ins != None && icnts != None && ins.Length == icnts.Length
                        Int ii = 0
                        While ii < ins.Length
                            Form fIn = ins[ii]
                            Int addIn = icnts[ii]
                            If fIn != None && addIn > 0
                                Int idx2 = -1
                                Int kk = 0
                                While kk < inFormsAgg.Length
                                    If inFormsAgg[kk] == fIn
                                        idx2 = kk
                                        kk = inFormsAgg.Length
                                    EndIf
                                    kk += 1
                                EndWhile

                                If idx2 == -1
                                    Int old2 = 0
                                    If inFormsAgg != None
                                        old2 = inFormsAgg.Length
                                    EndIf
                                    Form[] tmpF2 = new Form[old2 + 1]
                                    Int ci2 = 0
                                    While ci2 < old2
                                        tmpF2[ci2] = inFormsAgg[ci2]
                                        ci2 += 1
                                    EndWhile
                                    tmpF2[old2] = fIn
                                    inFormsAgg = tmpF2

                                    Int[] tmpI2 = new Int[old2 + 1]
                                    ci2 = 0
                                    While ci2 < old2
                                        tmpI2[ci2] = inCountsAgg[ci2]
                                        ci2 += 1
                                    EndWhile
                                    tmpI2[old2] = addIn
                                    inCountsAgg = tmpI2
                                Else
                                    inCountsAgg[idx2] = inCountsAgg[idx2] + addIn
                                EndIf

                                Int gidx = -1
                                Int zz = 0
                                While zz < totalNeedForms.Length
                                    If totalNeedForms[zz] == fIn
                                        gidx = zz
                                        zz = totalNeedForms.Length
                                    EndIf
                                    zz += 1
                                EndWhile
                                If gidx == -1
                                    Int old3 = 0
                                    If totalNeedForms != None
                                        old3 = totalNeedForms.Length
                                    EndIf
                                    Form[] tmpF3 = new Form[old3 + 1]
                                    Int ci3 = 0
                                    While ci3 < old3
                                        tmpF3[ci3] = totalNeedForms[ci3]
                                        ci3 += 1
                                    EndWhile
                                    tmpF3[old3] = fIn
                                    totalNeedForms = tmpF3

                                    Int[] tmpI3 = new Int[old3 + 1]
                                    ci3 = 0
                                    While ci3 < old3
                                        tmpI3[ci3] = totalNeedCounts[ci3]
                                        ci3 += 1
                                    EndWhile
                                    tmpI3[old3] = addIn
                                    totalNeedCounts = tmpI3
                                Else
                                    totalNeedCounts[gidx] = totalNeedCounts[gidx] + addIn
                                EndIf
                            EndIf
                            ii += 1
                        EndWhile
                    EndIf
                EndIf
            EndIf
            scan += 1
        EndWhile

        string s = groupName + " (" + occ + ")"

        string prodLine = "| Produces: "
        If outFormsAgg == None || outFormsAgg.Length == 0
            prodLine = prodLine + "(none)"
        Else
            Int oi2 = 0
            While oi2 < outFormsAgg.Length
                Form ff = outFormsAgg[oi2]
                string fname = ""
                If ff != None
                    fname = ff.GetName()
                EndIf
                prodLine = prodLine + Math.Ceiling(outCountsAgg[oi2] * ProductionMultiplierOverride.GetValue()) as Int + " " + fname
                If oi2 < outFormsAgg.Length - 1
                    prodLine = prodLine + ", "
                EndIf
                oi2 += 1
            EndWhile
        EndIf

        string consLine = "| Consumes: "
        If inFormsAgg == None || inFormsAgg.Length == 0
            consLine = consLine + "(none)"
        Else
            Int ii2 = 0
            While ii2 < inFormsAgg.Length
                Form ff2 = inFormsAgg[ii2]
                string fname2 = ""
                If ff2 != None
                    fname2 = ff2.GetName()
                EndIf
                consLine = consLine + Math.Ceiling(inCountsAgg[ii2] * ConsumptionMultiplierOverride.GetValue()) as Int + " " + fname2
                If ii2 < inFormsAgg.Length - 1
                    consLine = consLine + ", "
                EndIf
                ii2 += 1
            EndWhile
        EndIf

        s = s + "\n" + prodLine + "\n" + consLine

        Int oldG = 0
        If groupStrings != None
            oldG = groupStrings.Length
        EndIf
        string[] tmpGS = new string[oldG + 1]
        Int csi = 0
        While csi < oldG
            tmpGS[csi] = groupStrings[csi]
            csi += 1
        EndWhile
        tmpGS[oldG] = s
        groupStrings = tmpGS

        gi += 1
    EndWhile

    Int perPage = 5
    Int pagesCount = 0
    If groupStrings == None || groupStrings.Length == 0
        pagesCount = 0
    Else
        pagesCount = (groupStrings.Length + perPage - 1) / perPage
    EndIf

    If pagesCount > 0
        LedgerContents = new string[pagesCount]
        Int pageI = 0
        While pageI < pagesCount
            string pageText = ""
            Int startIndex = pageI * perPage
            Int endIndex = startIndex + perPage - 1
            If endIndex >= groupStrings.Length
                endIndex = groupStrings.Length - 1
            EndIf

            Int ii = startIndex
            While ii <= endIndex
                If pageText != ""
                    pageText = pageText + "\n\n"
                EndIf
                pageText = pageText + groupStrings[ii]
                ii += 1
            EndWhile

            LedgerContents[pageI] = pageText
            pageI += 1
        EndWhile
    Else
        LedgerContents = new string[1]
        LedgerContents[0] = "(none)"
    EndIf

    string missingLine = ""
    Int t = 0
    While t < totalNeedForms.Length
        Form needF = totalNeedForms[t]
        Int needAmt = totalNeedCounts[t]
        Int haveAmt = 0
        Int cc2 = 0
        While cc2 < allContainers.Length
            haveAmt += allContainers[cc2].GetItemCount(needF)
            cc2 += 1
        EndWhile
        If haveAmt < needAmt
            Int deficit = needAmt - haveAmt
            If missingLine != ""
                missingLine = missingLine + ", "
            EndIf
            string nmf = ""
            If needF != None
                nmf = needF.GetName()
            EndIf
            missingLine = missingLine + deficit + " " + nmf
        EndIf
        t += 1
    EndWhile
    If missingLine == ""
        missingLine = "Missing: (none)"
    Else
        missingLine = "Missing: " + missingLine + " for full production capacity"
    EndIf

    Int wagesTotal = 0
    If WagesEnabled != None && WagesEnabled.GetValueInt() > 0
        Int wagePer = 0
        If WageAmount != None
            wagePer = WageAmount.GetValueInt()
        EndIf
        Int rr = 0
        prodCount = ProducerList.GetSize()
        While rr < prodCount
            SPF_ProdObj rp = ProducerList.GetAt(rr) as SPF_ProdObj
            If rp != None
                Bool manned = False
                manned = rp.isManned
                If manned
                    wagesTotal += wagePer
                EndIf
            EndIf
            rr += 1
        EndWhile
    EndIf
    string wageLine = ""
    If WagesEnabled != None && WagesEnabled.GetValueInt() > 0
        wageLine = "Total wages per cycle: " + wagesTotal + " caps"
    Else
        wageLine = "Wages disabled"
    EndIf

    If LedgerContents.Length > 0
        Int last = LedgerContents.Length - 1
        LedgerContents[last] = LedgerContents[last] + "\n\n" + missingLine + "\n" + wageLine
    Else
        LedgerContents = new string[1]
        LedgerContents[0] = missingLine + "\n" + wageLine
    EndIf

    ; -----------------------------
    ; Show ledger pages as a series of Debug.MessageBox() calls (one OK each)
    ; -----------------------------
    Int pageIndex = 0
    While pageIndex < LedgerContents.Length
        string page = LedgerContents[pageIndex]
        If page == "" 
            page = "(empty)"
        EndIf

        Debug.MessageBox("=== Production Report ===\n\n" + page)
        pageIndex += 1
    EndWhile

    Float endTime = Utility.GetCurrentRealTime()
    Float delta = endTime - startTime
    Int elapsedMS = Math.Ceiling(delta * 1000) as Int
    Debug.Trace("GetProducerNames completed in " + elapsedMS + " ms")

    string result = ""
    Int r = 0
    While r < LedgerContents.Length
        If result != ""
            result = result + "\n\n-----\n\n"
        EndIf
        result = result + LedgerContents[r]
        r += 1
    EndWhile

    Return result
EndFunction