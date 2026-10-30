using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Pages;

[Authorize(Policy = ApplicationServices.BasicAccessPolicy)]
public sealed class NewLandParcelModel : PageModel
{
    public PartialViewResult OnGet(int landId) => Partial("_LandParcel", new LandParcel(landId));
}
