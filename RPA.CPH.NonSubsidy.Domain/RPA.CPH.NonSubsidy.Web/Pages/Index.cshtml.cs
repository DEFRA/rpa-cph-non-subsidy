using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Web.Services;
using X.PagedList;

namespace RPA.CPH.NonSubsidy.Web.Pages;

[Authorize(Policy = ApplicationServices.BasicAccessPolicy)]
public sealed class IndexModel(IUnitOfWork uow) : PageModel
{
    public IPagedList<Customer> Customers { get; private set; }

    public IActionResult OnGet(string searchString = null, [FromQuery] int page = 1, int pageSize = 20)
    {
        if (!ModelState.IsValid || page < 1 || pageSize < 1)
            return BadRequest("page and pageSize must be positive integers.");

        ViewData["SearchString"] = searchString;
        List<Customer> customers;
        if (!string.IsNullOrEmpty(searchString))
        {
            customers = uow.CustomerRepository.FindBy(x => x.SBI.ToString() == searchString.Trim())
                .OrderByDescending(x => x.Audit.LastUpdated).ThenBy(x => x.SBI).ToList();
        }
        else
        {
            customers = uow.CustomerRepository.GetAll()
                .OrderByDescending(x => x.Audit.LastUpdated).ThenBy(x => x.SBI).ToList();
        }

        Customers = new PagedList<Customer>(customers, page, pageSize);
        return Page();
    }
}
