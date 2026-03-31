Scriptname SPF_ProdObj extends WorkshopObjectScript

SPF_ProdMan Property Manager Auto Mandatory

Int Property IntervalDays = 1 Auto

Bool Property bHasCost = False Auto
Bool Property isManned = False Auto
FormList Property InputFormsList Auto
Int[] Property InputCounts Auto

FormList Property OutputFormsList Auto
Int[] Property OutputCounts Auto

ActorValue Property ResourceAV Auto
Int Property MinResourceCount = 0 Auto
Int Property TargetResourceCount = 0 Auto
Bool Property bOutputResource = False Auto

Bool Property bOverrideOutputWorkshop = False Auto
WorkshopScript Property OutputWorkshop Auto

Float LastProcessedGameDay = 0.0
Bool workForceChecked = False

; --- Cache arrays per instance ---
Form[] cachedInputForms = None
Form[] cachedOutputForms = None

Event OnInit()
    If Manager != None && !IsDisabled()
        Manager.RegisterProducer(self)
    EndIf
    If LastProcessedGameDay == 0.0
        LastProcessedGameDay = Utility.GetCurrentGameTime()
    EndIf
EndEvent

Event OnWorkshopObjectDestroyed(ObjectReference akReference)
    If Manager != None
        Manager.UnregisterProducer(self)
    EndIf
EndEvent

Function ProductionFail() ; This function is called when production fails for normal reasons
    Debug.Trace(self.getDisplayName() + " ProductionFail called.")
    if bOutputResource
        Float currentValue = Self.GetValue(ResourceAV)
        Float delta = MinResourceCount - currentValue
        Self.ModValue(ResourceAV, delta)
        Self.BlockActivation(True) ; block activation to prevent player from trying to use it when it doesn't have the required resource
        Self.SetOpen(True) ; Game generators often spawn with "true" meaning ff, which is confusing, but we need to set this to true to turn it off
        WorkshopParent.UpdateWorkshopRatingsForResourceObject(self, GetOwningWorkshop(), false)
    EndIf
EndFunction

Function ProcessIfDue(SPF_ProdMan mgr)
    Debug.Trace(self.getDisplayName() + " ProcessIfDue called.")
    if !workForceChecked
        workForceChecked = True
        isManned = RequiresActor()
    EndIf
    
    If mgr == None
        Return
    EndIf

    if mgr.needsFullReload
        ; This process is probably computationally expensive, but its only for reloads so its probably acceptable
        ObjectReference baseObject = PlaceAtMe(self.GetBaseObject(), 1, False, True)
        SPF_ProdObj baseScript = baseObject as SPF_ProdObj
        ; Update variables to match base
        IntervalDays = baseScript.IntervalDays
        bHasCost = baseScript.bHasCost
        isManned = baseScript.isManned
        InputFormsList = baseScript.InputFormsList
        InputCounts = baseScript.InputCounts
        OutputFormsList = baseScript.OutputFormsList
        OutputCounts = baseScript.OutputCounts
        ; Remove our dummy object
        baseObject.Delete()
    EndIf

    If !HasNeededLabor()
        Return ; skip this cycle if no labor assigned
    EndIf

    Float now = mgr.now
    Float elapsed = now - LastProcessedGameDay
    If elapsed < IntervalDays
        Return
    EndIf

    WorkshopScript owner = GetOwningWorkshop()
    If owner == None
        Return
    EndIf

    Form[] inForms = None
    Int[] inCounts = None
    If bHasCost
        ; --- use cached input array ---
        If cachedInputForms == None || mgr.needsReload
            cachedInputForms = FormsFromList(InputFormsList, False)
        EndIf
        inForms = cachedInputForms
        inCounts = InputCounts
        If inForms == None || inCounts == None || inForms.Length != inCounts.Length
            Debug.Trace(self + " SPF_ProdObj: input mismatch; skipping.")
            Return
        EndIf

        ; Apply consumption multiplier from the manager to inputs
        Float multiplier = mgr.GetConsumptionMultiplier()
        Int i = 0
        While i < inCounts.Length
            inCounts[i] = Math.Ceiling(inCounts[i] * multiplier) as Int
            i += 1
        EndWhile
    EndIf

    ; --- use cached output array ---
    If cachedOutputForms == None || mgr.needsReload
        cachedOutputForms = FormsFromList(OutputFormsList, True)
    EndIf
    Form[] outForms = cachedOutputForms
    Int[] outCounts = OutputCounts
    If outForms == None || outCounts == None || outForms.Length != outCounts.Length
        Debug.Trace(self + " SPF_ProdObj: output mismatch; skipping.")
        Return
    EndIf

    ; Apply production multiplier from the manager to outputs
    Float multiplier = mgr.GetProductionMultiplier()
    Int i = 0
    While i < outCounts.Length
        outCounts[i] = Math.Ceiling(outCounts[i] * multiplier) as Int
        i += 1
    EndWhile

    if RequiresActor() && mgr.WagesEnabled.GetValue() > 0
        if !mgr.ConsumeCapsFromNetwork(owner, Math.Floor(mgr.WageAmount.GetValue())) && mgr.WagePenalty.GetValue() > 0
            Debug.Trace(self + " SPF_ProdObj: insufficient caps for wages; skipping.")
            ProductionFail()
            Return ; insufficient caps for wages, skip this cycle
        EndIf
        isManned = True
    EndIf
    
    If bHasCost
        If !mgr.ConsumeFromNetwork(owner, inForms, inCounts)
            ProductionFail()
            Return ; insufficient inputs, skip this cycle
        EndIf
    EndIf

    WorkshopScript target = owner
    If bOverrideOutputWorkshop && OutputWorkshop != None
        target = OutputWorkshop
    ElseIf mgr.bOverrideOutputWorkshop && mgr.OutputWorkshop != None
        target = mgr.OutputWorkshop
    EndIf

    mgr.AddOutputsTo(target, outForms, outCounts)

    if bOutputResource
        Float currentValue = Self.GetValue(ResourceAV)
        Float delta = TargetResourceCount - currentValue
        Self.ModValue(ResourceAV, delta)
        Self.BlockActivation(True)
        Self.SetOpen(False) ; Game generators often spawn with "false" meaning on, which is confusing, but we need to set this to false to turn it on
        WorkshopParent.UpdateWorkshopRatingsForResourceObject(self, GetOwningWorkshop(), false)
    EndIf

    LastProcessedGameDay = now
EndFunction

WorkshopScript Function GetOwningWorkshop()
    If workshopID > 0 && WorkshopParent != None
        Return WorkshopParent.GetWorkshop(workshopID)
    EndIf
    Return None
EndFunction

Bool Function HasNeededLabor()
    ; If it does not require an actor, it always has needed labor
    If !IsManned
        Return True
    EndIf

    ; Otherwise, check if an actor is assigned
    Return GetAssignedActor() != NONE ; This is actually faster than IsActorAssigned(), because that does an extra IsBed check which this would (probably) never be
EndFunction

Form[] Function FormsFromList(FormList fl, bool output)
    string ioTag = "input"
    if output
        ioTag = "output"
    EndIf

    If fl == None
        Return new Form[0]
    EndIf
    Int n = fl.GetSize()
    Form[] arr = new Form[n]
    Int i = 0
    While i < n
        arr[i] = fl.GetAt(i)
        i += 1
    EndWhile
    Return arr
EndFunction