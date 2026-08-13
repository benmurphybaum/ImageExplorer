#pragma TextEncoding = "UTF-8"
#pragma rtGlobals=3				// Use modern global access method and strict wave access
#pragma DefaultTab={3,20,4}		// Set default tab width in Igor Pro 9 and later



// ============================================================================
//  Interactive Curves adjustment panel
//
//  Photoshop/Affinity-style curves editor. Drag the control points and the
//  curve recomputes live via MakeCurveBezier + BezierToPolygon.
//
//  Usage:      CurvesAdjustPanel()  (or Macros -> Curves Adjustment)
//    - Drag a point to move it.
//    - Click on empty graph area to add a new point there.
//    - Shift-click an interior point to delete it.
//    - Reset returns to the identity (straight) line.
// ============================================================================

static Constant kCA_Min    = 0     // min input/output value
static Constant kCA_Max    = 1     // max input/output value
static Constant kCA_HitPx  = 12    // pixel radius for grabbing a point
static Constant kCA_LUTpts = 256   // samples in the 1D output lookup wave
static Constant kCA_Eps    = 0.01  // min X gap between adjacent control points

static StrConstant kCA_DF = "root:Packages:CurvesAdjust"

Function CurvesAdjustPanel()
	String topWin = WinName(0, 1)
	String imageList = ImageNameList(topWin, ";")
	Wave theImage = ImageNameToWaveRef(topWin, StringFromList(0, imageList, ";"))
	if (!WaveExists(theImage))
		return 0
	endif
	
    DFREF dfSav = GetDataFolderDFR()
    NewDataFolder/O root:Packages
    NewDataFolder/O/S root:Packages:CurvesAdjust

    // Control points (init first time, or reset if stored points predate the 0-1 scale).
    WAVE/Z existingCurveX = $(kCA_DF + ":curveX")
    if (!WaveExists(existingCurveX) || WaveMax(existingCurveX) > kCA_Max || WaveMin(existingCurveX) < kCA_Min)
        Make/O/D curveX = {kCA_Min, kCA_Max}
        Make/O/D curveY = {kCA_Min, kCA_Max}
    endif
    
    Make/O/N=2 linear = x
    
    Make/O/D/N=0 hist
    Variable/G gDragIdx = -1

	String/G activeWindow = topWin
	String/G activeImage = NameOfWave(theImage)
    SetDataFolder dfSav

    CA_Recompute()

    DoWindow/F CurvesPanel
    if (V_flag != 0)
        return 0
    endif
    
    ModifyImage/W=$topWin $StringFromList(0, imageList, ";"), lookup=root:Packages:CurvesAdjust:fit_curveY

	NewPanel/EXT=0/HOST=$topWin/N=CurvesPanel/W=(0,0,300,300) as "Curves"
	DefineGuide/W=CurvesPanel controlGuide = {FT, 25}
    Display/HOST=CurvesPanel/N=Adjustment/FG=(FL, controlGuide, FR, FB) linear, root:Packages:CurvesAdjust:fit_curveY
    
    Wave hist = root:Packages:CurvesAdjust:hist
    ImageHistogram/DEST=hist theImage
    
    AppendToGraph/R/T hist
    AppendToGraph root:Packages:CurvesAdjust:curveY vs root:Packages:CurvesAdjust:curveX

		
	ModifyGraph grid(top)=0,noLabel(top)=2,axThick(top)=0,standoff(top)=0,log(right)=0,noLabel(right)=2,axThick(right)=0
	ModifyGraph mode(hist)=7,hbFill(hist)=5, rgb(hist) = (0,0,0, 10000)
	ModifyGraph axThick(left)=0.5,standoff(left)=0,btLen(left)=2,btThick(left)=0.5
	ModifyGraph axThick(bottom)=0.5,standoff(bottom)=0,btLen(bottom)=2,btThick(bottom)=0.5
	ModifyGraph hbFill(hist)=2, plusRGB(hist)=(0,0,0,5000),negRGB(hist)=(0,0,0,5000),useNegRGB(hist)=1,usePlusRGB(hist)=1
	ModifyGraph noLabel=2
	ModifyGraph tick=3,btLen=0,btThick=0
	ModifyGraph rgb(fit_curveY)=(0,0,0)
	
    ModifyGraph mode(curveY)=3, marker(curveY)=19, msize(curveY)=4, rgb(fit_curveY)=(0,0,0), rgb(curveY)=(0,0,0)//rgb(fit_curveY)=(1,26221,39321), rgb(curveY)=(1,26221,39321)
	ModifyGraph grid(bottom)=2,gridStyle(bottom)=3,gridHair(bottom)=1,gridRGB(bottom)=(0,0,0,16384)
	ModifyGraph grid(left)=2,gridStyle(left)=3,gridHair(left)=1,gridRGB(left)=(0,0,0,16384)
	ModifyGraph margin=14
    ModifyGraph manTick=0, mirror=0
    SetAxis left kCA_Min, kCA_Max
    SetAxis bottom kCA_Min, kCA_Max

    Button resetBtn,win=CurvesPanel, pos={8,2}, size={60,20}, title="Reset", proc=CA_ResetBtnProc
    Button applyBtn,win=CurvesPanel, pos={75,2}, size={60,20}, title="Apply", proc=CA_ApplyBtnProc
	
    SetWindow CurvesPanel, activeChildFrame = 0, hook(curves)=CurvesPanelHook

    return 0
End


Function GenerateNaturalCubicLUT(curveX, curveY, lut)
    Wave curveX, curveY, lut

    if (numpnts(curveX) != 3 || numpnts(curveY) != 3)
        Abort "GenerateNaturalCubicLUT requires exactly 3 control points."
    endif

    Variable x0 = curveX[0]
    Variable x1 = curveX[1]
    Variable x2 = curveX[2]

    Variable y0 = curveY[0]
    Variable y1 = curveY[1]
    Variable y2 = curveY[2]

    Variable h0 = x1 - x0
    Variable h1 = x2 - x1

    // Natural cubic spline:
    // second derivative is zero at x0 and x2.
    //
    // Solve for the second derivative at x1.
    Variable M1 = 3 * ((y2-y1)/h1 - (y1-y0)/h0) / (h0+h1)

    Variable M0 = 0
    Variable M2 = 0

    Variable i
    Variable x
    Variable t
    Variable dx

    Variable n = numpnts(lut)

    for (i = 0; i < n; i += 1)

        x = i / (n-1)

        if (x <= x1)

            dx = h0
            t = (x-x0)/dx

            // Cubic spline using endpoint second derivatives M0, M1
            multithread lut[i] = M0 * (x1-x)^3 / (6*dx) \
                   + M1 * (x-x0)^3 / (6*dx) \
                   + (y0 - M0*dx^2/6) * (x1-x)/dx \
                   + (y1 - M1*dx^2/6) * (x-x0)/dx

        else

            dx = h1
            t = (x-x1)/dx

            multithread lut[i] = M1 * (x2-x)^3 / (6*dx) \
                   + M2 * (x-x1)^3 / (6*dx) \
                   + (y1 - M1*dx^2/6) * (x2-x)/dx \
                   + (y2 - M2*dx^2/6) * (x-x1)/dx

        endif

    endfor
End

Function/Wave FitPoly(Wave curveX, Wave curveY, Variable size)
	Variable fitCoefs = DimSize(curveX, 0)

	Make/O/n=(size) $("fit_" + NameOfWave(curveY))/Wave = curvePoly
	SetScale/I x, 0,1, curvePoly
		
	if (fitCoefs == 2)
		Interpolate2/T=1/N=(size)/E=2/Y=$("fit_" + NameOfWave(curveY)) curveX, curveY
	elseif (fitCoefs == 3)
		GenerateNaturalCubicLUT(curveX, curveY, curvePoly)
	else
		Interpolate2/T=2/N=(size)/E=2/Y=$("fit_" + NameOfWave(curveY)) curveX, curveY
	endif

	curvePoly = limit(curvePoly, 0, 1)
	return curvePoly
End 



static Function CA_Recompute()

    DFREF dfSav = GetDataFolderDFR()

    SetDataFolder $kCA_DF

    WAVE curveX, curveY
    Wave fit = FitPoly(curveX, curveY, 256)
    SetDataFolder dfSav
End

// Return the index of the control point nearest to pixel (h,v),
// or -1 if none is within the grab radius.
static Function CA_FindPoint(String win, Variable h, Variable v)

    WAVE cx = $(kCA_DF + ":curveX")
    WAVE cy = $(kCA_DF + ":curveY")

    Variable i, n = numpnts(cx)
    Variable best = -1, bestDist = kCA_HitPx
    for (i = 0; i < n; i += 1)
        Variable px = PixelFromAxisVal(win, "bottom", cx[i])
        Variable py = PixelFromAxisVal(win, "left", cy[i])
        Variable d = sqrt((px - h)^2 + (py - v)^2)
        if (d <= bestDist)
            bestDist = d
            best = i
        endif
    endfor

    return best
End

// Insert a new control point, keeping the points sorted by X.
// Returns the index it was inserted at.
static Function CA_InsertPoint(Variable nx, Variable ny)

    WAVE cx = $(kCA_DF + ":curveX")
    WAVE cy = $(kCA_DF + ":curveY")

    nx = limit(nx, kCA_Min, kCA_Max)
    ny = limit(ny, kCA_Min, kCA_Max)

    Variable i, n = numpnts(cx)
    for (i = 0; i < n; i += 1)
        if (nx < cx[i])
            break
        endif
    endfor
    InsertPoints i, 1, cx, cy
    cx[i] = nx
    cy[i] = ny
    return i
End

// Move control point idx to pixel (h,v), applying curve constraints:
// endpoints keep their X pinned, interior points stay between neighbors,
// and Y is always clamped to the valid range.
static Function CA_MovePoint(Variable idx, String win, Variable h, Variable v)

    WAVE cx = $(kCA_DF + ":curveX")
    WAVE cy = $(kCA_DF + ":curveY")
    Variable n = numpnts(cx)

    Variable nx = AxisValFromPixel(win, "bottom", h)
    Variable ny = AxisValFromPixel(win, "left", v)
    
    if (numtype(ny) == 2 || numtype(nx) == 2)
    	return 0
    endif
    
    ny = limit(ny, kCA_Min, kCA_Max)

    if (idx == 0)
        nx = kCA_Min
    elseif (idx == n - 1)
        nx = kCA_Max
    else
        nx = limit(nx, cx[idx-1] + kCA_Eps, cx[idx+1] - kCA_Eps)
    endif

    cx[idx] = nx
    cy[idx] = ny
End

Function CurvesPanelHook(s)
    STRUCT WMWinHookStruct &s

    Variable handled = 0
    NVAR dragIdx = $(kCA_DF + ":gDragIdx")
    WAVE cx = $(kCA_DF + ":curveX")
    WAVE cy = $(kCA_DF + ":curveY")

    strswitch (s.eventName)
        case "mousedown":
            Variable idx = CA_FindPoint(s.winName, s.mouseLoc.h, s.mouseLoc.v)
            Variable shift = (s.eventMod & 2) != 0
            if (idx >= 0)

                if (shift && numpnts(cx) > 2 && idx != 0 && idx != numpnts(cx) - 1)
                    DeletePoints idx, 1, cx, cy
                    CA_Recompute()
                else
                    dragIdx = idx
                endif
                handled = 1
            else
            	
                Variable nx = AxisValFromPixel(s.winName, "bottom", s.mouseLoc.h)
                Variable ny = AxisValFromPixel(s.winName, "left", s.mouseLoc.v)
                if (nx > kCA_Min && nx < kCA_Max && ny >= kCA_Min && ny <= kCA_Max)
                    dragIdx = CA_InsertPoint(nx, ny)
                    CA_Recompute()
                    handled = 1
                endif
            endif
            break

        case "mousemoved":
        	idx = CA_FindPoint(s.winName, s.mouseLoc.h, s.mouseLoc.v)
        	if (idx >= 0)
        		ModifyGraph/W=CurvesPanel#Adjustment msize(curveY[idx])=5
        	else
        		ModifyGraph/W=CurvesPanel#Adjustment removeCustom(curveY) = 1
        	endif
        	
            if (dragIdx >= 0)
                CA_MovePoint(dragIdx, s.winName, s.mouseLoc.h, s.mouseLoc.v)
                CA_Recompute()
                handled = 1
            endif
            break

        case "mouseup":
            if (dragIdx >= 0)
                dragIdx = -1
                handled = 1
            endif
            break
    endswitch

    return handled
End

Function CA_ResetBtnProc(ba) : ButtonControl
    STRUCT WMButtonAction &ba

    if (ba.eventCode == 2)      // mouse up
        WAVE cx = $(kCA_DF + ":curveX")
        WAVE cy = $(kCA_DF + ":curveY")
        Redimension/N=2 cx, cy
        cx = {kCA_Min, kCA_Max}
        cy = {kCA_Min, kCA_Max}
        CA_Recompute()
    endif
    return 0
End


Function CA_ApplyBtnProc(ba) : ButtonControl
    STRUCT WMButtonAction &ba

    if (ba.eventCode == 2)      // mouse up
        SVAR activeWindow = $(kCA_DF + ":activeWindow")
        SVAR activeImage = $(kCA_DF + ":activeImage")
        WAVE lut = $(kCA_DF + ":fit_curveY")

        Wave img = ImageNameToWaveRef(activeWindow, activeImage)

        if (WaveExists(img))

//            Duplicate/O img, img_applied

            Variable minVal = WaveMin(img)
            Variable maxVal = WaveMax(img)
            Variable range = maxVal - minVal

            // Generate a dense 65536-point LUT from the 256-point curve.
            
            Wave curveX = $(kCA_DF + ":curveX")
            Wave curveY = $(kCA_DF + ":curveY")
            Wave lut16 = FitPoly(curveX, curveY, 65536)

            Variable lutMaxIndex = numpnts(lut16) - 1

            // Normalize image to [0,1], map to LUT index, apply LUT,
            // then map the result back to the original image range.
            MultiThread img = \
                minVal + lut16[round( \
                    min(1, max(0, (img-minVal)/range)) * lutMaxIndex \
                )] * range

            Wave hist = root:Packages:CurvesAdjust:hist
            ImageHistogram/DEST=hist img

        endif

        CA_Recompute()
    endif

    return 0
End

//Function PopMenuProc(pa) : PopupMenuControl
//	STRUCT WMPopupAction &pa
//
//	switch( pa.eventCode )
//		case 2: // mouse up
//			Variable popNum = pa.popNum
//			String popStr = pa.popStr
//		
//			CA_Recompute()      // rebuild the output LUT for the newly selected image
//			break
//		case -1: // control being killed
//			break
//	endswitch
//
//	return 0
//End


Menu "Image"
    "Curves Adjustment", /Q, CurvesAdjustPanel()
End
