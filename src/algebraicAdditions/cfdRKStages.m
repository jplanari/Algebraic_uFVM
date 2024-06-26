function cfdRKStages

global Region;

op = Region.operators;
fvSol = Region.foamDictionary.fvSolution;

RK = Region.foamDictionary.fvSchemes.ddtSchemes.RK;

if isfield(fvSol.solvers, 'pFinal')
    sol = fvSol.solvers.pFinal;
else
    sol = fvSol.solvers.p;
end

LapStencil = fvSol.AlguFVM.LapStencil;
PWIM = fvSol.AlguFVM.PWIM;

theNumberOfElements = cfdGetNumberOfElements;
theNumberOfFaces = cfdGetNumberOfFaces;

deltaT = cfdGetDeltaT;

nu = Region.foamDictionary.transportProperties.nu.propertyValue;

p = cfdGetField('p');
pCorr = cfdGetField('pCorr');
Uf = cfdGetField('Uf');
U = cfdGetField('U');

% Pressure predictor
pnPredCoef = fvSol.AlguFVM.pnPredCoef;

if pnPredCoef < 0.0
    deltaT = cfdGetDeltaT;
    
    % Calculate checkerboarding coefficient
    pLcp = -diag(op.OmegaIn)'*cfdGetInternalField(op.Gc*p, 'vvf').^2;
    pLp = -diag(op.OmegaSIn)'*(op.G*p).^2;
    
    if ~pLp == 0
        Ccb = 1 - pLcp/pLp;
    else
        Ccb = 0;
    end    

    pnPredCoef = 1 - Ccb;
end

% Higher order pPred:
% if pPredOrder == 0
%     pPred = 0;
% elseif pPredOrder == 1
%     pPred = p;
% elseif pPredOrder == 2
%     pPred = alpha*p^{n-1} + (1-alpha)*p^n;
% end
% Attuned with a 0-1 coefficient:
% pPred = pnPredCoef * pPred;
% For now just implement first order
pPred = pnPredCoef * p;

% Pressure reference cell and value
addSource = op.Pois.addSource;
Lap = op.Pois.Lap;

% Makes time-step dependent adjustments, so don't store changes
if Region.operators.Pois.pRefRequired
    iCell = Region.foamDictionary.fvSolution.AlguFVM.pRefCell;
    pCorrRefValue = Region.foamDictionary.fvSolution.AlguFVM.pRefValue - pPred(iCell);

   addSource(iCell) = addSource(iCell) + Lap(iCell,iCell)*pCorrRefValue; 
   Lap(iCell,iCell) = 2*Lap(iCell,iCell);
end

% Reset values for RK stages
dtpCorr = deltaT * cfdGetInternalField(pCorr, 'vsf');
UOld = U;
dUs = zeros(size(U, 1), RK.nStages);

for iStage = 1:RK.nStages + 1
    % Calculate fractional time step
    cdt = sum(RK.aTab(iStage,:))*deltaT;

    % Stage increment of U
    % if second order pPred is used, than the value can be extrapolated for
    % stages in this line
    Ucp = UOld + dUs*RK.aTab(iStage, :)' - cdt * op.Gc * pPred;
    Ucp = cfdBCUpdate(Ucp, 'Ucp');

    if ~((iStage == 1) && (RK.aTab(1, 1) == 0))     % Skip stage if (first & explicit)
        divUcp = cfdGetInternalField(op.Mc * Ucp, 'vsf');
        source = divUcp + cdt * addSource;

        % Include preconditioner (To do - 4)
        dtpCorr = cfdCheckpcg(-Lap, -source, sol.tolerance, sol.maxIter, speye(size(dtpCorr, 1)), speye(size(dtpCorr, 1)), dtpCorr);

        pCorr = cfdSetInternalField(pCorr, dtpCorr/cdt, 'vsf');
        pCorr = cfdBCUpdate(pCorr, 'pCorr');

        % Velocity update
        if strcmp(LapStencil, 'wide')
            U = Ucp - cdt * op.Gc * pCorr;
            U = cfdBCUpdate(U, 'U');
    
            if PWIM
                Uf = op.GamCS*Ucp - cdt * op.G * pCorr;
            else
                Uf = op.GamCS*U;
            end
        elseif strcmp(LapStencil, 'compact')
            Uf = op.GamCS*Ucp - cdt * op.G * pCorr;
    
            if PWIM
                U = Ucp - cdt * op.Gc * pCorr;
            else
                U = op.GamSC*Uf;
            end
            U = cfdBCUpdate(U, 'U');
        else
            error('LapStencil should be set to wide or compact')
        end
    end

    if iStage <= RK.nStages
        % Set convective
        Con = kron(eye(3), op.M*spdiags(Uf, 0, theNumberOfFaces, theNumberOfFaces)*op.PiCSM);
        Dif = nu * kron(eye(3), op.L);

        Region.evals.F = op.Omega\(Dif - Con);

        % Set delta U for this stage
        dUs(:, iStage) = -deltaT * (op.Omega\((Con - Dif)*U));
    end
end

p = pPred + pCorr;
p = cfdBCUpdate(p, 'p');

cfdSetField(p, 'p');
cfdSetField(p, 'pCorr');
cfdSetField(U, 'U');
cfdSetField(Uf, 'Uf');